"""Check native units/rules and optionally packets in disposable namespaces.

Build `(import ./tests/hermes-firewall.nix { inputs =
(builtins.getFlake (toString ./.)).inputs; }).policyFile` with `nix build --impure`.
Pass that JSON file here; add --packets only under
`unshare --user --map-root-user --net` with nftables and iproute2 on PATH.
"""

import json
import multiprocessing
import os
import re
import select
import shlex
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

PACKETS = "--packets" in sys.argv
if PACKETS:
    sys.argv.remove("--packets")
POLICY = json.loads(Path(sys.argv.pop(1)).read_text())


class LifecycleRegression(unittest.TestCase):
    def test_legacy_backend_switch_requires_stopped_container(self):
        script = POLICY["migrationCheck"]
        self.assertTrue(script, "a pre-switch check must enforce the legacy backend migration condition")
        legacy_path = "/run/current-system/etc/systemd/system/firewall.service"
        self.assertEqual(script.count(legacy_path), 1)
        with tempfile.TemporaryDirectory(prefix="hermes-migration-") as directory:
            root = Path(directory)
            legacy = root / "firewall.service"
            legacy.touch()
            systemctl = root / "systemctl"
            systemctl.write_text(
                "#!/bin/sh\n"
                '[ "$*" = "show --property=ActiveState --value container@hermes.service" ] || exit 99\n'
                '[ "$QUERY_FAILURE" = 0 ] || exit 1\n'
                'printf "%s\\n" "$CONTAINER_STATE"\n'
            )
            systemctl.chmod(0o700)
            script, count = re.subn(r"/nix/store/[^ /]+/bin/systemctl", shlex.quote(str(systemctl)), script)
            self.assertEqual(count, 1)
            check = root / "check.sh"
            check.write_text(script.replace(legacy_path, shlex.quote(str(legacy))))
            cases = [
                ("switch", "active", "0", False),
                ("test", "active", "0", False),
                ("switch", "activating", "0", False),
                ("switch", "deactivating", "0", False),
                ("switch", "reloading", "0", False),
                ("switch", "failed", "0", False),
                ("switch", "", "0", False),
                ("switch", "inactive", "1", False),
                ("switch", "inactive", "0", True),
                ("test", "inactive", "0", True),
                ("boot", "active", "1", True),
                ("dry-activate", "active", "1", True),
            ]
            for action, state, failure, allowed in cases:
                with self.subTest(action=action, state=state, query_failure=failure):
                    result = subprocess.run(
                        ["bash", "-eu", str(check), "/fixture/new-system", action],
                        env={"PATH": os.environ["PATH"], "CONTAINER_STATE": state, "QUERY_FAILURE": failure},
                        capture_output=True,
                        text=True,
                        check=False,
                    )
                    self.assertEqual(result.returncode == 0, allowed, result.stderr)
            legacy.unlink()
            result = subprocess.run(
                ["bash", "-eu", str(check), "/fixture/new-system", "switch"],
                env={"PATH": os.environ["PATH"], "CONTAINER_STATE": "active", "QUERY_FAILURE": "1"},
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, "native-to-native updates must not require stopping the container")

    def test_native_nixos_owns_confinement(self):
        self.assertTrue(POLICY["nativeOwnership"], "confinement must be owned by networking.nftables.tables")
        self.assertEqual(POLICY["backend"], "nftables")
        self.assertEqual(set(POLICY["tables"]), {"hermes-confinement", "nixos-fw", "nixos-nat"})
        self.assertEqual(POLICY["tables"]["hermes-confinement"]["family"], "inet")
        self.assertFalse(POLICY["flushRuleset"])
        self.assertFalse(POLICY["filterForward"], "do not introduce a host-wide FORWARD drop")
        self.assertIn('iifname "ve-hermes" jump from-container', POLICY["productionTable"]["content"])

    def test_stop_retains_all_managed_tables(self):
        self.assertEqual(POLICY["ExecStop"], [])
        self.assertNotRegex(POLICY["unit"], r"(?m)^ExecStop=.+")
        self.assertIn("RemainAfterExit=true", POLICY["unit"])
        self.assertIn("RuntimeDirectoryPreserve=true", POLICY["unit"])

    def test_initial_start_is_a_container_requirement(self):
        self.assertIn("container@hermes.service", POLICY["requiredBy"])
        self.assertIn("container@hermes.service", POLICY["before"])
        self.assertRegex(POLICY["unit"], r"(?m)^Before=.*container@hermes.service")
        self.assertEqual(POLICY["ExecStart"][:2], POLICY["ExecReload"][:2])
        self.assertEqual(POLICY["ExecStartPost"], POLICY["ExecReload"][2])
        self.assertEqual(POLICY["fixture"], POLICY["ExecStart"][1])

    def test_dns_only_input_preserves_host_initiated_replies(self):
        content = POLICY["tables"]["hermes-confinement"]["content"]
        self.assertIn("ct state { established, related } ct direction reply accept", content)
        self.assertNotIn("ct state { established, related } accept", content)
        self.assertEqual(content.count("meta nfproto ipv6 drop"), 3)
        self.assertEqual(content.count("priority filter - 10; policy accept"), 2)
        for protocol in ("tcp", "udp"):
            self.assertIn(f"ip daddr 198.18.0.1 {protocol} dport 53 accept", content)
            self.assertIn(f"iifname hf-agent {protocol} dport {{ 53 }} accept", POLICY["tables"]["nixos-fw"]["content"])

    def test_native_nat_and_atomic_replacement(self):
        self.assertIn('iifname { "hf-agent" } oifname "hf-uplink" masquerade', POLICY["tables"]["nixos-nat"]["content"])
        for key in ("fixture", "changedFixture"):
            rules = expanded_rules(POLICY[key])
            self.assertNotIn("flush ruleset", rules)
            for family, table in (("inet", "hermes-confinement"), ("inet", "nixos-fw"), ("ip", "nixos-nat")):
                self.assertIn(f"delete table {family} {table}", rules)
                self.assertIn(f"table {family} {table} {{", rules)
        self.assertIn("iptables", Path(POLICY["legacyStop"]).read_text())


def expanded_rules(path, previous=""):
    """Expand native includes without writing to the host's runtime directory.

    :param path: Generated NixOS nftables rules file.
    :param previous: Saved deletion manifest from the previous successful start.
    :returns: The complete nft transaction.
    """
    text = Path(path).read_text()
    return re.sub(r'^include "([^"]+)"$', lambda m: previous if m[1] == "/run/nftables/deletions.nft" else expanded_rules(m[1]), text, flags=re.MULTILINE)


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
            for port in (22, 53, 161, 443, 2022, 3030, 8765, 9002, 9558, 9120):
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
                    connection.sendall(connection.getpeername()[0].encode() if data == b"source" else data)
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
            elif op == "source":
                with socket.create_connection(tuple(args), timeout=0.3) as sock:
                    sock.sendall(b"source")
                    pipe.send(sock.recv(128).decode())
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
        self.assertEqual(len(uid_map), 3)
        self.assertEqual((uid_map[0], uid_map[2]), ("0", "1"))
        self.assertEqual([entry for entry in json.loads(run("nft", "-j", "list", "tables"))["nftables"] if "table" in entry], [])
        self.assertEqual(Path("/proc/sys/net/ipv4/ip_forward").read_text().strip(), "1")
        fixture = expanded_rules(POLICY["fixture"])
        saved = re.findall(r"^cp (\S+) /run/nftables/deletions.nft$", Path(POLICY["ExecStartPost"]).read_text(), re.MULTILINE)
        self.assertEqual(len(saved), 1)
        previous = Path(saved[0]).read_text()
        self.assertIn("delete table inet hermes-confinement", previous)
        reload_fixture = expanded_rules(POLICY["fixture"], previous)
        changed = expanded_rules(POLICY["changedFixture"], previous)
        self.assertEqual(reload_fixture.count("delete table inet hermes-confinement"), 2)
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
            other = Peer("hf-other", "198.20.0.2", "fd00:300::2")
            peers.append(other)
            servers = EchoServers()
            # An unrelated native table must survive installation and every reload.
            run("nft", "-f", "-", input="table inet unrelated {\n chain forward { type filter hook forward priority 0; policy accept; }\n}\n")
            cases = [
                (agent, "198.18.0.1", 53, "udp", True),
                (agent, "198.18.0.1", 53, "tcp", True),
                *[(agent, "198.18.0.1", port, "tcp", False) for port in (22, 2022, 3030, 8765, 9002, 9558)],
                (agent, "198.18.0.1", 161, "udp", False),
                (agent, "198.19.0.1", 53, "tcp", False),
                (agent, "10.23.0.88", 443, "tcp", True),
                (agent, "10.23.0.88", 161, "udp", True),
                (agent, "10.23.0.110", 22, "tcp", True),
                (agent, "10.23.0.110", 443, "tcp", False),
                (agent, "203.0.113.9", 443, "tcp", True),
                *[(agent, address, 443, "tcp", False) for address in denied],
                *[(lan, "198.19.0.1", port, "tcp", True) for port in (22, 2022, 3030, 8765)],
                (other, "203.0.113.9", 443, "tcp", True),
                (lan, "198.20.0.2", 9120, "tcp", True),
                (lan, "198.18.0.2", 9120, "tcp", False),
                (agent, "fd00:100::1", 22, "tcp", False),
                (agent, "fd00:100::1", 53, "udp", False),
                (lan, "fd00:200::1", 22, "tcp", True),
            ]
            self.assertEqual(len(cases), 30)
            for peer, address, port, protocol, _ in cases:
                self.assertTrue(peer.ask("probe", address, port, protocol), f"positive control {address}:{port}/{protocol}")
            legacy_env = dict(os.environ, PATH=POLICY["legacyPath"] + ":" + os.environ["PATH"])
            run(POLICY["legacyStart"], env=legacy_env)
            self.assertEqual(agent.ask("source", "203.0.113.9", 443), "198.19.0.1", "legacy NAT")
            # Positive controls need unrestricted INPUT and FORWARD.
            run(POLICY["legacyStop"], env=legacy_env)
            agent.ask("flood", ("10.23.0.7", 443), ("198.18.0.1", 22))
            lan.ask("flood", ("198.18.0.2", 9120))
            time.sleep(0.05)
            for peer in (agent, lan):
                stats = peer.ask("stop-flood")
                self.assertIsNone(stats["error"])
                self.assertGreater(stats["sent"], 0)
            time.sleep(0.05)
            self.assertGreater(servers.flood_count, 0)
            for peer in (agent, lan):
                self.assertGreater(peer.ask("count"), 0)
                peer.ask("reset-count")
            servers.flood_count = 0
            self.assertTrue(agent.ask("hold", "198.18.0.1", 22))
            with socket.create_connection(("198.18.0.2", 2022), timeout=0.3) as tunnel:
                self.assertTrue(probe("198.18.0.2", 2022, held=tunnel))
                run(POLICY["legacyStart"], env=legacy_env)
                run("nft", "-f", "-", input=fixture)
                self.assertEqual(agent.ask("source", "203.0.113.9", 443), "198.19.0.1", "coexisting NAT backends")
                run(POLICY["legacyStop"], env=legacy_env)
                self.assertEqual(agent.ask("source", "203.0.113.9", 443), "198.19.0.1", "native NAT after legacy cleanup")
                for peer, address, port, protocol, allowed in cases:
                    with self.subTest(address=address, port=port, protocol=protocol):
                        self.assertEqual(peer.ask("probe", address, port, protocol), allowed)
                self.assertFalse(agent.ask("held", "198.18.0.1", 22), "agent-originated established SSH must not survive")
                self.assertTrue(probe("198.18.0.2", 2022, held=tunnel), "host-originated SSH return path")
                self.assertTrue(probe("198.18.0.2", 2022), "new host-originated SSH connection")
                agent.ask("flood", ("10.23.0.7", 443), ("198.18.0.1", 22))
                lan.ask("flood", ("198.18.0.2", 9120))
                for _ in range(12):
                    run("nft", "-f", "-", input=reload_fixture)
                    before_stop = run("nft", "list", "ruleset")
                    for command in POLICY["ExecStop"]:
                        run(command)
                    self.assertEqual(run("nft", "list", "ruleset"), before_stop)
                    run("nft", "-f", "-", input=changed)
                    self.assertFalse(agent.ask("probe", "10.23.0.88", 443))
                    self.assertTrue(agent.ask("probe", "10.23.0.89", 443))
                    run("nft", "-f", "-", input=reload_fixture)
                    self.assertTrue(probe("198.18.0.2", 2022, held=tunnel))
                    self.assertTrue(agent.ask("probe", "198.18.0.1", 53, "udp"))
                # Both address families and the native firewall/NAT share one transaction.
                broken_rulesets = [
                    reload_fixture.replace("ip daddr 198.18.0.1", "invalid-nft-statement"),
                    reload_fixture.replace("meta nfproto ipv6 drop", "invalid-nft-statement"),
                    reload_fixture.replace("jump egress", "jump missing-chain"),
                ]
                for broken in broken_rulesets:
                    self.assertNotEqual(broken, reload_fixture)
                    before_failure = run("nft", "list", "ruleset")
                    result = subprocess.run(["nft", "-f", "-"], input=broken, text=True, capture_output=True, check=False)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("Error:", result.stderr)
                    self.assertEqual(run("nft", "list", "ruleset"), before_failure)
                    self.assertFalse(agent.ask("probe", "10.23.0.7", 443))
                    self.assertFalse(agent.ask("probe", "198.18.0.1", 22))
                    self.assertTrue(agent.ask("probe", "198.18.0.1", 53, "tcp"))
                for peer in (agent, lan):
                    stats = peer.ask("stop-flood")
                    self.assertIsNone(stats["error"])
                    self.assertGreater(stats["sent"], 100)
                time.sleep(0.05)
                self.assertEqual(lan.ask("count"), 0)
                self.assertEqual(agent.ask("count"), 0)
                self.assertEqual(servers.flood_count, 0)
                self.assertTrue(agent.ask("probe", "203.0.113.9", 443))
                self.assertTrue(lan.ask("probe", "198.19.0.1", 22))
            tables = [entry["table"] for entry in json.loads(run("nft", "-j", "list", "tables"))["nftables"] if "table" in entry]
            for family, name in (("inet", "hermes-confinement"), ("inet", "nixos-fw"), ("ip", "nixos-nat"), ("inet", "unrelated")):
                self.assertEqual(sum(table["family"] == family and table["name"] == name for table in tables), 1)
            print(f"Packet matrix: {len(cases)} positive controls and policy cases; 12 native reload/stop/update cycles; no denied flood deliveries.")
            print("Legacy/coexisting/native NAT source addresses verified; generated unit dependencies checked separately, not a systemd runtime test.")
            print("IPv6 INPUT exercised; IPv6 forwarding packets not covered (namespace forwarding sysctl is read-only and defaults off).")
        finally:
            for peer in peers:
                peer.close()
            if servers:
                servers.close()


if __name__ == "__main__":
    unittest.main()
