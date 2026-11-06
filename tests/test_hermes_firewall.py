"""Check lifecycle scripts, optionally exercising packets in disposable namespaces.

Evaluate `(import ./tests/hermes-firewall.nix { inputs =
(builtins.getFlake (toString ./.)).inputs; }).policy` with `nix eval --impure --json`.
Pass that JSON file here; add --packets only under
`unshare --user --map-root-user --net` with iptables and iproute2 on PATH.
"""

import json
import multiprocessing
import os
import re
import select
import socket
import subprocess
import sys
import threading
import time
import unittest
from pathlib import Path

PACKETS = "--packets" in sys.argv
if PACKETS:
    sys.argv.remove("--packets")
POLICY = json.loads(Path(sys.argv.pop(1)).read_text())


class LifecycleRegression(unittest.TestCase):
    def test_stop_does_not_remove_live_egress_boundary(self):
        self.assertGreater(len(POLICY["start"]), 100)
        # Only a restore transaction may replace a referenced policy chain.
        destructive = re.findall(
            r"^\s*iptables\s+-(?:D FORWARD -i \S+ -j hermes-egress|[FX] hermes-egress)\b.*",
            POLICY["stop"],
            re.MULTILINE,
        )
        self.assertEqual(destructive, [], "stop/reload exposes the permissive FORWARD path")

    def test_initial_start_is_a_container_requirement(self):
        self.assertEqual(POLICY["preStart"], POLICY["start"])
        self.assertEqual(POLICY["stop"], POLICY["start"])
        self.assertIn("container@hermes.service", POLICY["requiredBy"])
        self.assertIn("container@hermes.service", POLICY["before"])

    def test_dns_only_input_preserves_host_initiated_replies(self):
        rules = [line.strip() for line in POLICY["fixture"].splitlines() if line.strip().startswith("-A hermes-input ")]
        self.assertEqual(
            rules,
            [
                "-A hermes-input -m conntrack --ctstate ESTABLISHED,RELATED --ctdir REPLY -j ACCEPT",
                "-A hermes-input -d 198.18.0.1 -p udp --dport 53 -j ACCEPT",
                "-A hermes-input -d 198.18.0.1 -p tcp --dport 53 -j ACCEPT",
                "-A hermes-input -j DROP",
                "-A hermes-input -j DROP",
            ],
        )

    def test_scripts_parse_and_ipv6_is_conditional(self):
        for key in ("start", "stop", "preStart", "fixture", "changedFixture", "ipv4OnlyFixture"):
            with self.subTest(script=key):
                self.assertGreater(len(POLICY[key]), 100)
                subprocess.run(["bash", "-n"], input=POLICY[key], text=True, check=True)
        self.assertNotIn("ip6tables", POLICY["ipv4OnlyFixture"])


def run(*args, **kwargs):
    result = subprocess.run(args, text=True, capture_output=True, check=False, **kwargs)
    if result.returncode:
        raise AssertionError(f"{args}: exit {result.returncode}\n{result.stderr}")
    return result.stdout


def probe(address, port, protocol="tcp", held=None):
    family = socket.AF_INET6 if ":" in address else socket.AF_INET
    sock = held or socket.socket(family, socket.SOCK_STREAM if protocol == "tcp" else socket.SOCK_DGRAM)
    try:
        sock.settimeout(0.15)
        if held is None:
            sock.connect((address, port))
        sock.send(b"probe")
        return sock.recv(32) == b"probe"
    except (OSError, TimeoutError):
        return False
    finally:
        if held is None:
            sock.close()


class EchoServers:
    def __init__(self):
        self.sockets = []
        self.flood_count = 0
        self.stopped = False
        for family in (socket.AF_INET, socket.AF_INET6):
            for port in (22, 53, 161, 443, 2022, 9002, 9558, 9120):
                for kind in (socket.SOCK_STREAM, socket.SOCK_DGRAM):
                    sock = socket.socket(family, kind)
                    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                    if family == socket.AF_INET6:
                        sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
                    sock.bind(("::" if family == socket.AF_INET6 else "0.0.0.0", port))
                    if kind == socket.SOCK_STREAM:
                        sock.listen()
                    elif family == socket.AF_INET:
                        sock.setsockopt(socket.IPPROTO_IP, socket.IP_PKTINFO, 1)
                    else:
                        sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_RECVPKTINFO, 1)
                    self.sockets.append(sock)
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def echo(self, connection):
        with connection:
            connection.settimeout(5)
            try:
                while data := connection.recv(128):
                    connection.sendall(data)
            except OSError:
                pass

    def serve(self):
        while not self.stopped:
            readable, _, _ = select.select(self.sockets, [], [], 0.05)
            for sock in readable:
                if sock.type == socket.SOCK_STREAM:
                    conn, _ = sock.accept()
                    threading.Thread(target=self.echo, args=(conn,), daemon=True).start()
                else:
                    data, ancillary, _, addr = sock.recvmsg(128, 128)
                    if data == b"flood":
                        self.flood_count += 1
                    else:
                        sock.sendmsg([data], ancillary, 0, addr)

    def close(self):
        self.stopped = True
        self.thread.join()
        for sock in self.sockets:
            sock.close()


def peer_worker(pipe):
    os.unshare(os.CLONE_NEWNET)
    pipe.send(os.getpid())
    commands = pipe.recv()
    for command in commands:
        run(*command)
    servers = EchoServers()
    held = None
    flood_stop = threading.Event()
    flood_thread = None
    pipe.send("ready")
    try:
        while True:
            op, *args = pipe.recv()
            if op == "probe":
                pipe.send(probe(*args))
            elif op == "hold":
                held = socket.create_connection(tuple(args), timeout=0.3)
                pipe.send(probe(*args, held=held))
            elif op == "held":
                pipe.send(probe(*args, held=held))
            elif op == "count":
                pipe.send(servers.flood_count)
            elif op == "reset-count":
                servers.flood_count = 0
                pipe.send("reset")
            elif op == "flood":
                flood_stop.clear()
                flood_stats = {"sent": 0, "error": None}

                def flood(targets=tuple(args), stats=flood_stats):
                    try:
                        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
                            while not flood_stop.wait(0.001):
                                for target in targets:
                                    sock.sendto(b"flood", tuple(target))
                                    stats["sent"] += 1
                    except Exception as error:  # noqa: BLE001 - Report thread failures to the parent assertion.
                        stats["error"] = str(error)

                flood_thread = threading.Thread(target=flood, daemon=True)
                flood_thread.start()
                pipe.send("flooding")
            elif op == "stop-flood":
                flood_stop.set()
                flood_thread.join()
                pipe.send(flood_stats)
            elif op == "close":
                break
            else:
                raise ValueError(op)
    finally:
        flood_stop.set()
        if held:
            held.close()
        servers.close()


class Peer:
    def __init__(self, host_interface, address, v6, aliases=()):
        context = multiprocessing.get_context("fork")
        self.pipe, child = context.Pipe()
        self.process = context.Process(target=peer_worker, args=(child,))
        self.process.start()
        assert self.pipe.poll(5), "peer did not create its namespace"
        pid = self.pipe.recv()
        run("ip", "link", "add", host_interface, "type", "veth", "peer", "name", "hf-peer")
        run("ip", "link", "set", "hf-peer", "netns", str(pid))
        prefix = address.rsplit(".", 1)[0]
        v6prefix = v6.rsplit(":", 1)[0]
        run("ip", "addr", "add", prefix + ".1/24", "dev", host_interface)
        run("ip", "-6", "addr", "add", v6prefix + ":1/64", "dev", host_interface, "nodad")
        run("ip", "link", "set", host_interface, "up")
        commands = [
            ["ip", "link", "set", "lo", "up"],
            ["ip", "addr", "add", address + "/24", "dev", "hf-peer"],
            ["ip", "-6", "addr", "add", v6 + "/64", "dev", "hf-peer", "nodad"],
            ["ip", "link", "set", "hf-peer", "up"],
            ["ip", "route", "add", "default", "via", prefix + ".1"],
            ["ip", "-6", "route", "add", "default", "via", v6prefix + ":1"],
        ]
        for alias in aliases:
            commands.append(["ip", "addr", "add", alias + "/32", "dev", "lo"])
            run("ip", "route", "add", alias + "/32", "via", address)
        self.pipe.send(commands)
        assert self.pipe.poll(5), "peer configuration failed"
        assert self.pipe.recv() == "ready"

    def ask(self, op, *args):
        assert self.process.is_alive(), "dead peer cannot prove a firewall denial"
        self.pipe.send((op, *args))
        assert self.pipe.poll(5), f"peer timed out: {op}"
        return self.pipe.recv()

    def close(self):
        if self.process.is_alive():
            self.pipe.send(("close",))
            self.process.join(3)
        if self.process.is_alive():
            self.process.terminate()
            self.process.join()


@unittest.skipUnless(PACKETS, "pass --packets inside a disposable user/network namespace")
class PacketRegression(unittest.TestCase):
    def test_packet_policy_and_lifecycle(self):
        # Refuse to touch a populated/production namespace, even when run as root.
        links = json.loads(run("ip", "-j", "link", "show"))
        self.assertEqual([link["ifname"] for link in links], ["lo"])
        uid_map = Path("/proc/self/uid_map").read_text().split()
        self.assertEqual((uid_map[0], uid_map[2]), ("0", "1"))
        self.assertEqual(Path("/proc/sys/net/ipv4/ip_forward").read_text().strip(), "1")
        fixture = POLICY["fixture"]
        self.assertIn("hf-agent", fixture)
        self.assertNotIn("ve-hermes", fixture)
        run("ip", "link", "set", "lo", "up")
        denied = ["10.23.0.7", "172.16.20.1", "192.168.20.1", "169.254.20.1", "100.64.20.1"]
        peers = []
        servers = None
        try:
            agent = Peer("hf-agent", "198.18.0.2", "fd00:100::2")
            peers.append(agent)
            lan = Peer("hf-uplink", "198.19.0.2", "fd00:200::2", denied + ["10.23.0.88", "10.23.0.89", "10.23.0.110", "203.0.113.9"])
            peers.append(lan)
            servers = EchoServers()
            # Global service accepts and permissive forwarding are intentional controls.
            for tool in ("iptables", "ip6tables"):
                run(tool, "-w", "-A", "INPUT", "-j", "ACCEPT")
                run(tool, "-w", "-N", "fixture-native")
                run(tool, "-w", "-A", "fixture-native", "-j", "ACCEPT")
                run(tool, "-w", "-A", "FORWARD", "-j", "fixture-native")
            cases = [
                (agent, "198.18.0.1", 53, "udp", True),
                (agent, "198.18.0.1", 53, "tcp", True),
                *[(agent, "198.18.0.1", port, "tcp", False) for port in (22, 2022, 9002, 9558)],
                (agent, "198.18.0.1", 161, "udp", False),
                (agent, "198.19.0.1", 53, "tcp", False),
                (agent, "10.23.0.88", 443, "tcp", True),
                (agent, "10.23.0.88", 161, "udp", True),
                (agent, "10.23.0.110", 22, "tcp", True),
                (agent, "10.23.0.110", 443, "tcp", False),
                (agent, "203.0.113.9", 443, "tcp", True),
                *[(agent, address, 443, "tcp", False) for address in denied],
                (lan, "198.19.0.1", 22, "tcp", True),
                (lan, "198.18.0.2", 9120, "tcp", False),
                (agent, "fd00:100::1", 22, "tcp", False),
                (agent, "fd00:100::1", 53, "udp", False),
                (lan, "fd00:200::1", 22, "tcp", True),
            ]
            for peer, address, port, protocol, _ in cases:
                self.assertTrue(peer.ask("probe", address, port, protocol), f"positive control {address}:{port}/{protocol}")
            agent.ask("flood", ("10.23.0.7", 443), ("198.18.0.1", 22))
            lan.ask("flood", ("198.18.0.2", 9120))
            time.sleep(0.05)
            for peer in peers:
                stats = peer.ask("stop-flood")
                self.assertIsNone(stats["error"])
                self.assertGreater(stats["sent"], 0)
            time.sleep(0.05)
            self.assertGreater(servers.flood_count, 0)
            for peer in peers:
                self.assertGreater(peer.ask("count"), 0)
                peer.ask("reset-count")
            servers.flood_count = 0
            self.assertTrue(agent.ask("hold", "198.18.0.1", 22))
            with socket.create_connection(("198.18.0.2", 2022), timeout=0.3) as tunnel:
                self.assertTrue(probe("198.18.0.2", 2022, held=tunnel))
                run("bash", "-eu", input=fixture)
                for peer, address, port, protocol, allowed in cases:
                    with self.subTest(address=address, port=port, protocol=protocol):
                        self.assertEqual(peer.ask("probe", address, port, protocol), allowed)
                self.assertFalse(agent.ask("held", "198.18.0.1", 22), "agent-originated established SSH must not survive")
                self.assertTrue(probe("198.18.0.2", 2022, held=tunnel), "host-originated SSH return path")
                self.assertTrue(probe("198.18.0.2", 2022), "new host-originated SSH connection")
                agent.ask("flood", ("10.23.0.7", 443), ("198.18.0.1", 22))
                lan.ask("flood", ("198.18.0.2", 9120))
                for cycle in range(12):
                    # Native reload/stop removes only its own chain; policy must survive.
                    run("bash", "-eu", input=fixture)
                    run("iptables", "-w", "-F", "fixture-native")
                    run("bash", "-eu", input=POLICY["changedFixture"])
                    self.assertFalse(agent.ask("probe", "10.23.0.88", 443))
                    self.assertTrue(agent.ask("probe", "10.23.0.89", 443))
                    run("iptables", "-w", "-A", "fixture-native", "-j", "ACCEPT")
                    run("bash", "-eu", input=fixture)
                    self.assertTrue(probe("198.18.0.2", 2022, held=tunnel))
                # A malformed restore must fail atomically, not publish an empty chain.
                for old in ("-A hermes-egress -j ACCEPT", "-A hermes-egress -j DROP"):
                    broken = fixture.replace(old, "-A hermes-missing -j ACCEPT")
                    self.assertNotEqual(broken, fixture)
                    result = subprocess.run(["bash", "-eu"], input=broken, text=True, capture_output=True, check=False)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("No chain/target/match", result.stderr)
                    self.assertFalse(agent.ask("probe", "10.23.0.7", 443))
                    self.assertFalse(agent.ask("probe", "198.18.0.1", 22))
                for peer in peers:
                    stats = peer.ask("stop-flood")
                    self.assertIsNone(stats["error"])
                    self.assertGreater(stats["sent"], 100)
                time.sleep(0.05)
                self.assertEqual(lan.ask("count"), 0)
                self.assertEqual(agent.ask("count"), 0)
                self.assertEqual(servers.flood_count, 0)
                self.assertTrue(agent.ask("probe", "203.0.113.9", 443))
                self.assertTrue(lan.ask("probe", "198.19.0.1", 22))
            for tool in ("iptables", "ip6tables"):
                forward = run(tool, "-w", "-S", "FORWARD").splitlines()
                input_rules = run(tool, "-w", "-S", "INPUT").splitlines()
                self.assertIn("-o hf-agent", forward[1])
                self.assertIn("-i hf-agent -j hermes-egress", forward[2])
                self.assertIn("-i hf-agent -j hermes-input", input_rules[1])
                self.assertEqual(sum("-j hermes-egress" in line for line in forward), 1)
                self.assertEqual(sum("-j hermes-input" in line for line in input_rules), 1)
            print(f"Packet matrix: {len(cases)} positive controls and policy cases; 12 reload/stop/update cycles; no denied flood deliveries.")
            print("IPv6 INPUT exercised; IPv6 forwarding packets not covered (namespace forwarding sysctl is read-only and defaults off).")
        finally:
            for peer in peers:
                peer.close()
            if servers:
                servers.close()


if __name__ == "__main__":
    unittest.main()
