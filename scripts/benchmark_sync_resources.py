"""Compare Windows sync binaries on identical isolated synthetic dictionaries."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import statistics
import tempfile
import time

import diagnose_windows_resources as metrics
from test_lan_sync import Node


def benchmark(binary, interval, duplicate, seconds):
    rows = [dict(key=dict(namespace="rime_q/full-pinyin/v1", text=f"Synthetic{i}", code="ce shi"), weight=1)
            for i in range(7908)]
    with tempfile.TemporaryDirectory(prefix="rimeq-sync-benchmark-") as temporary:
        node = Node(binary.resolve(), Path(temporary) / "sync", "Synthetic")
        handle = None
        try:
            node.call("create", group="Synthetic", name="Synthetic")
            assert node.call("capture", rows=rows)["job"] is None
            handle = metrics.kernel.OpenProcess(0x0400 | 0x0010, False, node.process.pid)
            metrics.checked(handle)
            node.call("status")  # warm up both paths
            started, latencies = time.perf_counter(), []
            before = metrics.sample(handle)
            for _ in range(20):
                start = time.perf_counter()
                node.call("status")
                latencies.append(1000 * (time.perf_counter() - start))
            after = metrics.sample(handle)
            status = metrics.summarize(before, after, time.perf_counter() - started, os.cpu_count())
            status["median_ms"] = statistics.median(latencies)
            captures = []
            for _ in range(3):
                before = metrics.sample(handle)
                start = time.perf_counter()
                assert node.call("capture", rows=rows)["job"] is None
                elapsed = time.perf_counter() - start
                captures.append(dict(wall_ms=elapsed * 1000, **metrics.summarize(before, metrics.sample(handle), elapsed, os.cpu_count())))
            # Emulate only the coordinator's status frequency, without loading
            # the WPF frontend or claiming this is real host input performance.
            before = metrics.sample(handle)
            start = time.perf_counter()
            next_poll, requests = start, 0
            while time.perf_counter() - start < seconds:
                if time.perf_counter() >= next_poll:
                    for _ in range(duplicate):
                        node.call("status")
                        requests += 1
                    next_poll += interval
                time.sleep(0.05)
            elapsed = time.perf_counter() - start
            idle = metrics.summarize(before, metrics.sample(handle), elapsed, os.cpu_count())
            idle.update(seconds=elapsed, requests=requests)
            return dict(binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(), status_20=status, unchanged_captures=captures, idle_status_polling=idle)
        finally:
            if handle:
                metrics.kernel.CloseHandle(handle)
            node.stop()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--before", type=Path, required=True)
    parser.add_argument("--after", type=Path, required=True)
    parser.add_argument("--seconds", type=int, default=20)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    report = dict(fixture="7908 identical synthetic records, warm cache, single isolated service, no network peers, no UI or real typing",
                  logical_processors=os.cpu_count(),
                  before=benchmark(args.before, 1, 2, args.seconds),
                  after=benchmark(args.after, 10, 1, args.seconds))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
