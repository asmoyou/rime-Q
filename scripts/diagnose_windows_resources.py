"""Read-only Windows process/sync sampling; never exports dictionary contents.

CPU percentages use the Task Manager convention (all logical CPUs = 100%).
I/O counters include file, pipe and socket traffic, not just physical disk I/O.
"""
import argparse
import ctypes as c
from ctypes import wintypes as w
import datetime as dt
import json
import os
from pathlib import Path
import socket
import statistics
import struct
import time


class Memory(c.Structure):
    _fields_ = [("cb", w.DWORD), ("PageFaultCount", w.DWORD)] + [
        (name, c.c_size_t) for name in (
            "PeakWorkingSetSize", "WorkingSetSize", "QuotaPeakPagedPoolUsage",
            "QuotaPagedPoolUsage", "QuotaPeakNonPagedPoolUsage",
            "QuotaNonPagedPoolUsage", "PagefileUsage", "PeakPagefileUsage", "PrivateUsage")]


class IO(c.Structure):
    _fields_ = [(name, c.c_ulonglong) for name in (
        "ReadOperationCount", "WriteOperationCount", "OtherOperationCount",
        "ReadTransferCount", "WriteTransferCount", "OtherTransferCount")]


kernel = c.WinDLL("kernel32", use_last_error=True)
kernel.OpenProcess.argtypes = [w.DWORD, w.BOOL, w.DWORD]
kernel.OpenProcess.restype = w.HANDLE
kernel.CloseHandle.argtypes = [w.HANDLE]
kernel.GetProcessTimes.argtypes = [w.HANDLE] + [c.POINTER(w.FILETIME)] * 4
kernel.GetProcessIoCounters.argtypes = [w.HANDLE, c.POINTER(IO)]
psapi = c.WinDLL("psapi", use_last_error=True)
psapi.GetProcessMemoryInfo.argtypes = [w.HANDLE, c.POINTER(Memory), w.DWORD]


def checked(ok):
    if not ok:
        raise c.WinError(c.get_last_error())


def sample(handle):
    times = [w.FILETIME() for _ in range(4)]
    checked(kernel.GetProcessTimes(handle, *(c.byref(t) for t in times)))
    memory, io = Memory(), IO()
    memory.cb = c.sizeof(memory)
    checked(psapi.GetProcessMemoryInfo(handle, c.byref(memory), memory.cb))
    checked(kernel.GetProcessIoCounters(handle, c.byref(io)))
    return dict(cpu=sum((t.dwHighDateTime << 32) + t.dwLowDateTime for t in times[2:]) / 1e7,
                rss=memory.WorkingSetSize, private=memory.PrivateUsage,
                read=io.ReadTransferCount, write=io.WriteTransferCount,
                read_ops=io.ReadOperationCount, write_ops=io.WriteOperationCount)


def status(root):
    # The control credential stays in memory; neither it nor peer identities are emitted.
    descriptor = json.loads((root / "control.json").read_text(encoding="utf-8-sig"))
    address, port = descriptor["address"].rsplit(":", 1)
    if address != "127.0.0.1":
        raise ValueError("Expected IPv4 loopback control endpoint")
    request = json.dumps(dict(token=descriptor["token"], request=dict(action="status"))).encode()
    with socket.create_connection((address, int(port)), timeout=10) as connection:
        connection.sendall(struct.pack("!I", len(request)) + request)

        def read(size):
            data = bytearray()
            while len(data) < size:
                part = connection.recv(size - len(data))
                if not part:
                    raise EOFError("Incomplete status response")
                data.extend(part)
            return data

        size, = struct.unpack("!I", read(4))
        if not 0 < size <= 96 * 1024 * 1024:
            raise ValueError("Invalid response size")
        result = json.loads(read(size))
    if not result.get("ok"):
        raise RuntimeError("Status request failed")
    return result["result"]


def safe_status(value):
    members = value.get("members", [])
    return dict(enabled=value.get("enabled"), rows=value.get("rows"),
                members=len(members), online=sum(bool(m.get("online")) for m in members),
                confirmed=sum(bool(m.get("applied")) for m in members),
                needs_upgrade=sum(bool(m.get("needs_upgrade")) for m in members),
                waiting_input=value.get("waiting_input"),
                stage=value.get("progress", {}).get("stage"))


def summarize(before, after, seconds, cores):
    return dict(cpu_seconds=round(after["cpu"] - before["cpu"], 6),
                cpu_percent=round(100 * (after["cpu"] - before["cpu"]) / seconds / cores, 4),
                rss_mib=round(after["rss"] / 2**20, 2),
                private_mib=round(after["private"] / 2**20, 2),
                read_bytes=after["read"] - before["read"],
                write_bytes=after["write"] - before["write"],
                read_operations=after["read_ops"] - before["read_ops"],
                write_operations=after["write_ops"] - before["write_ops"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--process", action="append", required=True, help="name:PID")
    parser.add_argument("--seconds", type=int, default=60)
    parser.add_argument("--status-requests", type=int, default=20)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.seconds < 1 or not 0 <= args.status_requests <= 100:
        parser.error("Invalid sample duration or request count")
    root = Path(os.environ["APPDATA"]) / "RimeQ" / "sync"
    handles = {}
    try:
        for process in args.process:
            name, pid = process.rsplit(":", 1)
            handle = kernel.OpenProcess(0x0400 | 0x0010, False, int(pid))
            checked(handle)
            handles[name] = handle
        cores = os.cpu_count()
        start_status = status(root)
        report = dict(started_at=dt.datetime.now(dt.timezone.utc).isoformat(), logical_processors=cores,
                      status_before=safe_status(start_status), samples=[])
        before = previous = {name: sample(handle) for name, handle in handles.items()}
        started = prior_time = time.perf_counter()
        for i in range(args.seconds):
            time.sleep(max(0, started + i + 1 - time.perf_counter()))
            current = {name: sample(handle) for name, handle in handles.items()}
            now = time.perf_counter()
            report["samples"].append(dict(elapsed_seconds=round(now-started, 3), processes={
                name: summarize(previous[name], value, now-prior_time, cores)
                for name, value in current.items()}))
            previous, prior_time = current, now
        elapsed = now - started
        report["duration_seconds"] = elapsed
        report["baseline"] = {name: summarize(before[name], value, elapsed, cores)
                              for name, value in current.items()}
        end_status = status(root)
        report["status_after"] = safe_status(end_status)
        report["revision_unchanged"] = start_status["revision"] == end_status["revision"]
        # Deliberately bounded read-only request burst, separate from baseline.
        if args.status_requests:
            before = {name: sample(handle) for name, handle in handles.items()}
            started, latencies = time.perf_counter(), []
            for _ in range(args.status_requests):
                tick = time.perf_counter()
                status(root)
                latencies.append((time.perf_counter() - tick) * 1000)
            elapsed = time.perf_counter() - started
            after = {name: sample(handle) for name, handle in handles.items()}
            report["status_probe"] = dict(requests=args.status_requests, duration_seconds=elapsed,
                latency_median_ms=statistics.median(latencies), latency_max_ms=max(latencies),
                processes={name: summarize(before[name], value, elapsed, cores) for name, value in after.items()})
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(json.dumps({k: v for k, v in report.items() if k != "samples"}, ensure_ascii=False, indent=2))
    finally:
        for handle in handles.values():
            kernel.CloseHandle(handle)


if __name__ == "__main__":
    main()
