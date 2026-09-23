"""Exercise the VM test's wait helpers without booting a VM."""

import ast
from contextlib import redirect_stdout
import io
import json
from pathlib import Path
import re
import textwrap
import unittest
from unittest.mock import Mock


NIX = Path(__file__).with_name("default.nix")
INTERPOLATIONS = {
    "pkgs.bash": "/nix/store/test-bash",
    "pkgs.coreutils": "/nix/store/test-coreutils",
    "pkgs.python3": "/nix/store/test-python",
    "pkgs.hello": "/nix/store/test-hello",
    "pkgs.util-linux": "/nix/store/test-util-linux",
    "home": "/test/hermes",
    "toString uid": "1100",
    "python": "/test/python",
    **{f"./{name}.py": f"/test/{name}.py" for name in (
        "diagnostics", "gateway", "peer", "probe", "seed", "worker",
    )},
}


def load_helpers():
    source = NIX.read_text()
    marker = "    testScript = ''\n"
    if source.count(marker) != 1:
        raise AssertionError("expected one testScript")
    script = source.split(marker, 1)[1].rsplit("    '';", 1)[0]
    script = re.sub(r"\$\{([^}]+)\}", lambda match: INTERPOLATIONS[match[1]], script)
    if "${" in script or "''" in script:
        raise AssertionError("unsupported Nix interpolation or escape")
    tree = ast.parse(textwrap.dedent(script), filename=str(NIX))
    helpers: list[ast.stmt] = [node for node in tree.body if isinstance(
        node, (ast.Import, ast.ImportFrom, ast.FunctionDef),
    )]
    names = {node.name for node in helpers if isinstance(node, ast.FunctionDef)}
    if not {"c", "user", "gateway_ready", "wait_for_worker_file"} <= names:
        raise AssertionError("missing VM wait helpers")
    namespace = {}
    exec(compile(ast.Module(body=helpers, type_ignores=[]), str(NIX), "exec"), namespace)
    return namespace


class WaitDiagnosticsTests(unittest.TestCase):
    def setUp(self):
        self.helpers = load_helpers()
        self.machine = Mock()
        self.collect = Mock(return_value="Result=exit-code\nExecMainStatus=203\nstartup journal")
        self.helpers.update(machine=self.machine, c=self.collect)

    def test_gateway_timeout_collects_once_and_preserves_failure(self):
        original = RuntimeError("gateway readiness timed out\nlast poll failed")
        self.machine.wait_until_succeeds.side_effect = original
        output = io.StringIO()
        with redirect_stdout(output), self.assertRaises(Exception) as caught:
            self.helpers["gateway_ready"]()
        self.assertIs(caught.exception.__cause__, original)
        self.machine.wait_until_succeeds.assert_called_once()
        self.assertEqual(self.machine.wait_until_succeeds.call_args.kwargs, {"timeout": 60})
        self.assertIn("systemctl --user is-active hermes-gateway.service",
                      self.machine.wait_until_succeeds.call_args.args[0])
        commands = [call.args[0] for call in self.collect.call_args_list]
        self.assertEqual(len(commands), 5)
        self.assertEqual(len(set(commands)), 5)
        gateway = next(command for command in commands if "systemctl --user show" in command)
        controller = next(command for command in commands if "systemctl show hermes-agent.service" in command)
        self.assertIn("runuser -u hermes", gateway)
        self.assertIn("XDG_RUNTIME_DIR=/run/user/1100", gateway)
        for command in (gateway, controller):
            for field in ("Result", "ExecMainCode", "ExecMainStatus", "ExecStart", "ExecStopPost"):
                self.assertIn("-p " + field, command)
        self.assertEqual(sum("journalctl" in command for command in commands), 2)
        self.assertTrue(any("_SYSTEMD_USER_UNIT=hermes-gateway.service" in command for command in commands))
        self.assertTrue(any("-u hermes-agent.service" in command for command in commands))
        self.assertTrue(any("/test/diagnostics.py /test/hermes" in command for command in commands))
        self.assertEqual(output.getvalue(), "")
        self.assertEqual(len(str(caught.exception).splitlines()), 1)
        record = json.loads(str(caught.exception))
        self.assertEqual(record["error"], str(original))
        self.assertEqual(len(record["diagnostics"]), 5)
        self.assertTrue(all(value == self.collect.return_value for value in record["diagnostics"].values()))

    def test_file_timeout_uses_same_collector_and_requested_deadline(self):
        for timeout in (60, 180):
            with self.subTest(timeout=timeout):
                self.collect.reset_mock()
                self.machine.reset_mock()
                original = RuntimeError("worker file timed out")
                self.machine.wait_until_succeeds.side_effect = original
                with self.assertRaises(AssertionError) as caught:
                    self.helpers["wait_for_worker_file"]("/test/hermes/worker-ready", timeout=timeout)
                self.assertIs(caught.exception.__cause__, original)
                self.machine.wait_until_succeeds.assert_called_once_with(
                    "systemd-run --machine=hermes --wait --quiet "
                    "/nix/store/test-coreutils/bin/test -f /test/hermes/worker-ready",
                    timeout=timeout,
                )
                record = json.loads(str(caught.exception))
                self.assertEqual(record["error"], str(original))
                self.assertEqual(set(record["diagnostics"]), {
                    "controller-journal", "gateway-journal", "controller-status",
                    "gateway-status", "worker-state",
                })
                self.assertEqual(self.collect.call_count, 5)

    def prepare_gateway(self):
        invocation = "a" * 32
        started = {"pid": 123, "invocation": invocation}
        directory = "/test/hermes/gateway-starts/" + invocation

        def command_result(command):
            if "systemctl --user show hermes-gateway.service -p InvocationID --value" in command:
                return invocation
            if "systemctl --user show hermes-gateway.service -p MainPID --value" in command:
                return "123"
            if command == "systemctl show hermes-agent.service -p InvocationID --value":
                return "b" * 32
            if command == "cat " + directory + "/started.json":
                return json.dumps(started)
            return self.collect(command)

        self.helpers["c"] = command_result
        return started, directory

    def test_success_does_not_collect_diagnostics(self):
        expected = self.prepare_gateway()
        self.assertEqual(self.helpers["gateway_ready"](), expected)
        self.assertEqual(self.machine.wait_until_succeeds.call_count, 3)
        self.assertTrue(all(call.kwargs == {"timeout": 60}
                            for call in self.machine.wait_until_succeeds.call_args_list))
        self.helpers["wait_for_worker_file"]("/test/hermes/worker-ready", timeout=180)
        self.assertEqual(self.machine.wait_until_succeeds.call_args.kwargs, {"timeout": 180})
        self.collect.assert_not_called()

    def test_gateway_file_timeouts_do_not_collect_twice(self):
        self.prepare_gateway()
        for successful_polls in (1, 2):
            with self.subTest(successful_polls=successful_polls):
                self.collect.reset_mock()
                self.machine.reset_mock()
                original = RuntimeError("gateway marker timed out")
                self.machine.wait_until_succeeds.side_effect = [None] * successful_polls + [original]
                with self.assertRaises(AssertionError) as caught:
                    self.helpers["gateway_ready"]()
                self.assertIs(caught.exception.__cause__, original)
                self.assertEqual(self.collect.call_count, 5)
                self.assertEqual(self.machine.wait_until_succeeds.call_count, successful_polls + 1)
                record = json.loads(str(caught.exception))
                self.assertEqual(record["error"], str(original))

    def test_collection_failure_does_not_mask_timeout_or_skip_sources(self):
        for failed_source in range(5):
            with self.subTest(failed_source=failed_source):
                self.collect.reset_mock()
                original = RuntimeError("gateway readiness timed out")
                self.machine.wait_until_succeeds.side_effect = original
                results = [self.collect.return_value] * 5
                results[failed_source] = RuntimeError("collector unavailable\ntransport failed")
                self.collect.side_effect = results
                with self.assertRaises(AssertionError) as caught:
                    self.helpers["gateway_ready"]()
                self.assertIs(caught.exception.__cause__, original)
                self.assertEqual(self.collect.call_count, 5)
                self.assertEqual(len(str(caught.exception).splitlines()), 1)
                record = json.loads(str(caught.exception))
                self.assertEqual(record["error"], str(original))
                values = list(record["diagnostics"].values())
                self.assertEqual(values[failed_source],
                                 "diagnostic collection failed: collector unavailable\ntransport failed")
                self.assertEqual(values.count(self.collect.return_value), 4)


if __name__ == "__main__":
    unittest.main()
