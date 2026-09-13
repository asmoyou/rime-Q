#!/usr/bin/env python3
"""Exercise the real encrypted service with isolated processes and data.

This is a process/network protocol test, not a VM or real-input acceptance test.
Never opens the user's Rime Q data directory. Reports exclude pairing secrets.
"""
import argparse
import concurrent.futures
import json
import os
from pathlib import Path
import socket
import ssl
import struct
import subprocess
import tempfile
import time

MAX_FRAME = 4 * 1024 * 1024


def exact(stream, size):
    result = bytearray()
    while len(result) < size:
        chunk = stream.recv(size - len(result))
        if not chunk:
            raise ConnectionError("connection closed")
        result.extend(chunk)
    return result


def request(root, action, **values):
    descriptor = json.loads((root / "control.json").read_text())
    host, port = descriptor["address"].rsplit(":", 1)
    body = json.dumps({"token": descriptor["token"], "request": {"action": action, **values}}, ensure_ascii=False).encode()
    with socket.create_connection((host, int(port)), timeout=150) as stream:
        stream.sendall(struct.pack(">I", len(body)) + body)
        size = struct.unpack(">I", exact(stream, 4))[0]
        if size > MAX_FRAME:
            raise ValueError("oversized response")
        response = json.loads(exact(stream, size))
    if not response.get("ok"):
        raise RuntimeError(response.get("error", "service request failed"))
    return response["result"]


def until(check, message, seconds=30):
    deadline = time.monotonic() + seconds
    last = None
    while time.monotonic() < deadline:
        try:
            last = check()
            if last:
                return last
        except (OSError, ValueError, RuntimeError):
            pass
        time.sleep(0.1)
    raise AssertionError(message)


class Node:
    def __init__(self, binary, root, name):
        self.binary, self.root, self.name = binary, root, name
        self.process = None
        self.log = None
        self.start()

    def start(self):
        self.root.mkdir(exist_ok=True)
        self.log = (self.root / "process.log").open("ab")
        env = {key: value for key, value in os.environ.items() if key.upper() in {"SYSTEMROOT", "WINDIR", "USERPROFILE", "APPDATA", "LOCALAPPDATA", "TEMP", "TMP", "PATH", "HOME"}}
        self.process = subprocess.Popen([str(self.binary), "serve", "--root", str(self.root), "--bind", "127.0.0.1", "--isolated", "--no-discovery"],
                                        stdout=self.log, stderr=self.log, env=env,
                                        creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
        try:
            until(lambda: self.root.joinpath("control.json").exists() and self.call("status"), "node failed to start")
        except Exception:
            self.process.kill(); self.process.wait(timeout=5); self.log.close()
            raise

    def call(self, action, **values):
        return request(self.root, action, **values)

    def address(self):
        return "127.0.0.1:" + str(until(lambda: self.call("status")["port"], "listener did not start"))

    def stop(self, crash=False):
        if self.process and self.process.poll() is None:
            if crash:
                self.process.kill()
            else:
                try:
                    self.call("shutdown")
                except OSError:
                    pass
                except RuntimeError as error:
                    if str(error) != "sync service is restarting":
                        raise
            try:
                self.process.wait(timeout=8)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        if self.log:
            self.log.close()
        self.process = None


def pair(inviter, guest):
    invite = inviter.call("invite")
    with concurrent.futures.ThreadPoolExecutor(1) as executor:
        joined = executor.submit(guest.call, "join", address=inviter.address(), invite=invite["invite"], code=invite["code"], name=guest.name)
        pending = until(lambda: inviter.call("status")["pending"], "pairing did not request approval")
        inviter.call("approve", id=pending[0]["id"])
        joined.result(timeout=20)
    guest.address()


def change(node, text, weight):
    node.call("fixture_change", changes=[{"key": {"namespace": "rime_q/full-pinyin/v1", "text": text, "code": "ce shi"}, "weight": weight}])


def rows(node):
    return {row["key"]["text"]: row["weight"] for row in node.call("fixture_rows")["rows"]}


def reject_unauthorized(inviter, guest):
    invitation = inviter.call("invite")
    wrong = "000000" if invitation["code"] != "000000" else "000001"
    try:
        guest.call("join", address=inviter.address(), invite=invitation["invite"], code=wrong, name=guest.name)
        raise AssertionError("wrong pairing code was accepted")
    except RuntimeError:
        pass
    assert not inviter.call("status")["pending"]
    assert not guest.call("status")["group"]
    inviter.call("cancel_invite")
    # A TLS channel alone never authorizes a peer to read dictionary data.
    host, port = inviter.address().rsplit(":", 1)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    context.minimum_version = ssl.TLSVersion.TLSv1_3
    with socket.create_connection((host, int(port)), timeout=5) as raw:
        with context.wrap_socket(raw, server_hostname="rimeq.local") as stream:
            size = struct.unpack(">I", exact(stream, 4))[0]
            assert size <= MAX_FRAME
            hello = json.loads(exact(stream, size))
            forged = {"mode":"Sync", "id":hello["id"], "group":inviter.call("status")["group"]["id"], "members":[], "signature":"A"*86}
            data = json.dumps(forged).encode()
            stream.sendall(struct.pack(">I",len(data))+data)
            try:
                assert stream.recv(1) == b"", "unauthorized peer received application data"
            except (ssl.SSLError, ConnectionResetError):
                pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--nodes", type=int, default=6)
    parser.add_argument("--output", type=Path, default=Path("artifacts/lan-sync-process-report.json"))
    args = parser.parse_args()
    if not 6 <= args.nodes <= 50:
        parser.error("use 6..50 isolated nodes")
    cases = []
    start = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="rimeq-lan-process-") as temporary:
        nodes = []
        try:
            for i in range(args.nodes):
                nodes.append(Node(args.binary.resolve(), Path(temporary) / f"node-{i}", f"Test device {i}"))
            nodes[0].call("create", group="Isolated test group", name=nodes[0].name)
            nodes[0].address()
            reject_unauthorized(nodes[0], nodes[1])
            cases.append("wrong_pairing_code_and_forged_peer_rejected")
            invite = nodes[0].call("invite")
            with concurrent.futures.ThreadPoolExecutor(1) as executor:
                waiting = executor.submit(nodes[1].call, "join", address=nodes[0].address(), invite=invite["invite"], code=invite["code"], name=nodes[1].name)
                until(lambda: nodes[0].call("status")["pending"], "cancel test never requested approval")
                assert nodes[1].call("cancel_join")["cancelled"]
                try:
                    waiting.result(timeout=5)
                    raise AssertionError("cancelled guest still joined")
                except RuntimeError as error:
                    assert "pairing cancelled" in str(error)
            until(lambda: not nodes[0].call("status")["pending"], "cancelled approval remained on inviter", 5)
            assert nodes[1].call("status")["group"] is None
            cases.append("cancel_join_clears_remote_approval_and_allows_retry")
            for node in nodes[1:]:
                pair(nodes[0], node)
            cases.append("each_device_joins_once")
            until(lambda: all(len(node.call("status")["members"]) == args.nodes for node in nodes), "membership did not propagate", 60)
            for i, node in enumerate(nodes):
                node.call("add_peer", address=nodes[(i + 1) % len(nodes)].address())
            for i, node in enumerate(nodes):
                change(node, f"隔离词条{i}", i + 1)
            until(lambda: all(len(rows(n)) == args.nodes for n in nodes), "records did not converge", 60)
            cases.append("multi_origin_encrypted_convergence")
            # Loss of the original inviter must not prevent other peers syncing.
            nodes[0].stop()
            change(nodes[1], "主机离线", 17)
            until(lambda: all(rows(n).get("主机离线") == 17 for n in nodes[1:]), "founder outage blocked the group", 60)
            cases.append("founder_offline_relay")
            nodes[0].start()
            for node in nodes[1:]:
                node.call("add_peer", address=nodes[0].address())
            until(lambda: rows(nodes[0]).get("主机离线") == 17, "restarted node did not catch up", 60)
            cases.append("restart_and_new_address_catchup")
            change(nodes[0], "删除测试", 10)
            until(lambda: all(rows(n).get("删除测试") == 10 for n in nodes), "seed did not converge")
            nodes[-1].call("pause")
            change(nodes[0], "删除测试", None)
            change(nodes[-1], "删除测试", 200)
            nodes[-1].call("resume")
            for n in nodes:
                n.call("sync_now")
            until(lambda: all("删除测试" not in rows(n) for n in nodes), "offline learning resurrected deletion", 60)
            cases.append("offline_delete_wins")
            change(nodes[2], "删除测试", 1)
            until(lambda: all(rows(n).get("删除测试") == 1 for n in nodes), "causal relearning failed")
            cases.append("causal_relearning")
            nodes[-1].stop(crash=True)
            nodes[-1].start()
            for n in nodes[:-1]:
                n.call("add_peer", address=nodes[-1].address())
            change(nodes[2], "崩溃恢复", 9)
            until(lambda: all(rows(n).get("崩溃恢复") == 9 for n in nodes), "crash recovery failed", 60)
            cases.append("abrupt_termination_durable_recovery")
            removed = nodes[-1].call("status")["id"]
            nodes[0].call("remove", id=removed)
            until(lambda: all(any(m["id"] == removed and m["removed"] for m in n.call("status")["members"]) for n in nodes[:-1]), "revocation did not propagate", 60)
            cases.append("member_removal_propagates")
            until(lambda: not nodes[-1].call("status")["enabled"], "removed device did not receive a signed removal notice", 60)
            cases.append("removed_device_notified_without_dictionary_transfer")
            nodes[-1].call("leave")
            nodes[-1].stop()
            nodes[-1].start()
            assert nodes[-1].call("status")["id"] != removed, "rejoin reused revoked identity"
            pair(nodes[2], nodes[-1])
            for node in nodes[:-1]:
                node.call("add_peer", address=nodes[-1].address())
            change(nodes[-1], "重新加入", 3)
            until(lambda: all(rows(n).get("重新加入")==3 for n in nodes), "re-enrolled device did not converge", 60)
            cases.append("leave_rotate_identity_and_rejoin_through_nonfounder")
        finally:
            for n in nodes:
                n.stop()
    report = {"kind": "isolated_processes_real_tls", "vm_test": False, "nodes": args.nodes, "passed": cases, "seconds": round(time.monotonic() - start, 2)}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(report, ensure_ascii=True))


if __name__ == "__main__":
    main()
