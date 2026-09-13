#!/usr/bin/env python3
"""Real multi-host networking in dedicated Docker network/storage namespaces.

No ports or host data directories are exposed. Only resources with the unique
run prefix are created or removed. Reports contain synthetic fixture data only.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import subprocess
import time
import uuid


def docker(*args, data=None, timeout=180):
    result = subprocess.run(["docker", *args], input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f"Docker {args[0]} failed (exit {result.returncode}): " + result.stderr.decode(errors="replace")[:600])
    return result.stdout


def wait_for(check, label, seconds=90):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if check():
            return
        time.sleep(0.5)
    raise AssertionError(label)


class Node:
    def __init__(self, name, image, network):
        self.name = name
        docker("run", "--detach", "--name", name, "--network", network, "--memory", "384m", "--cpus", "1", "--pids-limit", "128", image)
        wait_for(self.ready, "sandbox service did not start", 25)

    def ready(self):
        try:
            self.call("status")
            return True
        except RuntimeError:
            return False

    def call(self, action, **values):
        return json.loads(docker("exec", "--interactive", self.name, "/app/rimeq-sync", "control", "--root", "/state",
                                 data=json.dumps({"action": action, **values}, ensure_ascii=False).encode()))

    def address(self, network):
        value = json.loads(docker("inspect", self.name))[0]
        return value["NetworkSettings"]["Networks"][network]["IPAddress"] + ":42437"

    def rows(self):
        return {r["key"]["text"]: r["weight"] for r in self.call("fixture_rows")["rows"]}

    def change(self, text, weight):
        self.call("fixture_change", changes=[{"key":{"namespace":"rime_q/full-pinyin/v1","text":text,"code":"ce shi"},"weight":weight}])


def parallel(nodes, operation):
    with ThreadPoolExecutor(min(8, len(nodes))) as executor:
        return list(executor.map(operation, nodes))


def pair(inviter, guest, network):
    invitation = inviter.call("invite")
    guest.call("discover")
    found = []
    def discovered_invitation():
        found[:] = [d for d in guest.call("status")["discovered"] if d["invite"] == invitation["invite"]]
        return bool(found)
    wait_for(discovered_invitation, "current invitation was not advertised by mDNS", 30)
    with ThreadPoolExecutor(1) as executor:
        joining = executor.submit(guest.call, "join", address=found[0]["address"], invite=invitation["invite"], code=invitation["code"], name=guest.name)
        def awaiting_approval():
            if joining.done():
                joining.result()
            return bool(inviter.call("status")["pending"])
        wait_for(awaiting_approval, "pairing did not request local approval", 25)
        pending = inviter.call("status")["pending"][0]
        inviter.call("approve", id=pending["id"])
        joining.result(timeout=30)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--image", default="rimeq-lan-sync:test")
    parser.add_argument("--nodes", type=int, default=6)
    parser.add_argument("--output", type=Path, default=Path("artifacts/lan-sync-sandbox-report.json"))
    parser.add_argument("--keep-on-failure", action="store_true")
    args = parser.parse_args()
    if not 6 <= args.nodes <= 50:
        parser.error("use 6..50 nodes")
    prefix = "rimeq-lan-" + uuid.uuid4().hex[:10]
    main_net, left_net, right_net = (prefix + suffix for suffix in ["-all", "-left", "-right"])
    created_networks, nodes, cases = [], [], []
    started = time.monotonic()
    failed = None
    def passed(label):
        cases.append(label)
        print("PASS " + label, flush=True)
    try:
        for network in [main_net, left_net, right_net]:
            # Docker's internal bridge rules also drop link-local multicast on
            # some hosts. A dedicated standard bridge models a multicast LAN;
            # containers expose no host ports and receive no host data mounts.
            docker("network", "create", "--label", "rimeq.sync.test=" + prefix, network)
            created_networks.append(network)
        for i in range(args.nodes):
            nodes.append(Node(prefix + "-" + str(i), args.image, main_net))
        print(f"Started {len(nodes)} isolated network/storage sandboxes", flush=True)
        nodes[0].call("create", group="Isolated LAN validation", name=nodes[0].name)
        for node in nodes[1:]:
            pair(nodes[0], node, main_net)
        wait_for(lambda: all(n == len(nodes) for n in parallel(nodes, lambda n: len(n.call("status")["members"]))), "membership convergence")
        passed("one_enrollment_per_device")
        threads = int(docker("stats", "--no-stream", "--format", "{{.PIDs}}", nodes[0].name))
        assert threads < 16, "repeated invitations leaked discovery threads"
        passed("discovery_threads_bounded_after_all_enrollments")
        wait_for(lambda: all(n > 0 for n in parallel(nodes, lambda n: len(n.call("status")["discovered"]))), "mDNS discovery between sandboxes")
        passed("real_multicast_discovery")
        parallel(list(enumerate(nodes)), lambda item: item[1].change("沙盒词条" + str(item[0]), item[0] + 1))
        wait_for(lambda: all(len(r) == len(nodes) for r in parallel(nodes, lambda n:n.rows())), "initial concurrent convergence")
        passed("all_origin_tls_convergence")
        # Separate actual network interfaces, not merely application pause flags.
        split = len(nodes) // 2
        for i, node in enumerate(nodes):
            docker("network", "connect", left_net if i < split else right_net, node.name)
            docker("network", "disconnect", main_net, node.name)
        time.sleep(2)
        nodes[0].change("左侧离线学习", 13)
        nodes[-1].change("右侧离线学习", 19)
        wait_for(lambda: all(r.get("左侧离线学习") == 13 for r in parallel(nodes[:split],lambda n:n.rows())), "left partition local sync")
        wait_for(lambda: all(r.get("右侧离线学习") == 19 for r in parallel(nodes[split:],lambda n:n.rows())), "right partition local sync")
        assert all("右侧离线学习" not in r for r in parallel(nodes[:split],lambda n:n.rows())), "partition isolation failed"
        assert all("左侧离线学习" not in r for r in parallel(nodes[split:],lambda n:n.rows())), "partition isolation failed"
        passed("independent_network_partitions")
        for i, node in enumerate(nodes):
            docker("network", "connect", main_net, node.name)
            docker("network", "disconnect", left_net if i < split else right_net, node.name)
        wait_for(lambda: all(r.get("左侧离线学习") == 13 and r.get("右侧离线学习") == 19 for r in parallel(nodes,lambda n:n.rows())), "network reunion and new addresses", 120)
        passed("partition_reunion_without_manual_addresses")
        docker("stop", "--time", "3", nodes[0].name)
        nodes[1].change("创建者已关机", 7)
        wait_for(lambda: all(r.get("创建者已关机") == 7 for r in parallel(nodes[1:],lambda n:n.rows())), "founder-offline networking")
        passed("no_required_master_device")
        docker("start", nodes[0].name)
        wait_for(nodes[0].ready, "restart startup")
        wait_for(lambda: nodes[0].rows().get("创建者已关机") == 7, "restart durable catchup")
        passed("sandbox_restart_and_catchup")
        nodes[0].change("删除屏障", 10)
        wait_for(lambda: all(r.get("删除屏障") == 10 for r in parallel(nodes,lambda n:n.rows())), "delete seed propagation")
        docker("network", "disconnect", main_net, nodes[-1].name)
        nodes[-1].change("删除屏障", 900)
        nodes[1].change("删除屏障", None)
        wait_for(lambda: all("删除屏障" not in r for r in parallel(nodes[:-1],lambda n:n.rows())), "deletion propagation")
        nodes[2].change("删除屏障", 1)
        docker("network", "connect", main_net, nodes[-1].name)
        wait_for(lambda: all(r.get("删除屏障") == 1 for r in parallel(nodes,lambda n:n.rows())), "late old generation must stay suppressed", 120)
        passed("late_offline_learning_after_delete_and_relearn")
        before = parallel(nodes, lambda n:n.rows())
        parallel(nodes,lambda n:n.call("sync_now"))
        time.sleep(3)
        assert parallel(nodes,lambda n:n.rows()) == before, "duplicate delivery changed weights"
        passed("duplicate_transfer_is_idempotent")
    except Exception as error:
        failed = str(error)
        raise
    finally:
        report={"kind":"docker_network_and_storage_namespaces","separate_kernel_vms":False,"nodes":len(nodes),"network":"dedicated Docker bridges with multicast and default outbound routing; no published ports; no host data mounts",
                "image":args.image,"image_id":docker("image","inspect",args.image,"--format","{{.Id}}").decode().strip(),"prefix":prefix,"passed":cases,"failure":failed,"seconds":round(time.monotonic()-started,2)}
        args.output.parent.mkdir(parents=True,exist_ok=True)
        args.output.write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding="utf-8")
        if not failed or not args.keep_on_failure:
            for node in nodes:
                docker("rm","--force",node.name)
            for network in reversed(created_networks):
                docker("network","rm",network)
        else:
            print("Preserved only this test's sandboxes for diagnosis: " + prefix,flush=True)


if __name__ == "__main__":
    main()
