"""Check the test shim's PID/readiness provenance without starting Hermes."""

import importlib.util
import json
import os
from pathlib import Path
import runpy
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


class RecoveryIdentityProofTests(unittest.TestCase):
    def setUp(self):
        self.shim = runpy.run_path(str(Path(__file__).with_name("gateway.py")))
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name)
        (self.home / "cron").mkdir()
        self.database = self.home / "cron/executions.db"
        self.owner = {"id": "execution-owner", "pid": 12345, "process_started_at": 67890}
        source = (Path(__file__).resolve().parents[2]
                  / "systems/nix-slopfucker/hermes-recovery-identity.py")
        spec = importlib.util.spec_from_file_location("test_recovery_identity", source)
        assert spec is not None and spec.loader is not None
        self.identity = importlib.util.module_from_spec(spec)
        with patch.dict(sys.modules, {spec.name: self.identity}):
            spec.loader.exec_module(self.identity)

    def create_ledger(self, status="running"):
        with sqlite3.connect(self.database) as db:
            db.execute("CREATE TABLE executions "
                       "(id TEXT PRIMARY KEY, pid INTEGER, process_started_at INTEGER, status TEXT)")
            db.execute("INSERT INTO executions VALUES (?, ?, ?, ?)",
                       (*self.owner.values(), status))

    def proof_with_helper(self, *, unavailable=False, start=None):
        local = self.identity.Identity(self.owner["pid"], "inaccessible")
        reply = subprocess.CompletedProcess([], 0, json.dumps({
            "version": 1, "pid": self.owner["pid"], "state": "live",
            "start_time": self.owner["process_started_at"] if start is None else start,
        }), "")
        with patch.object(self.identity, "local_identity", return_value=local) as local_probe:
            with patch.object(self.identity.subprocess, "run", return_value=reply,
                              side_effect=FileNotFoundError("helper unavailable") if unavailable else None) as helper:
                proof = self.shim["recovery_identity_proof"](self.home, self.identity)
        self.assertTrue(local_probe.call_args_list)
        for call in local_probe.call_args_list:
            self.assertEqual(call.args, (self.owner["pid"],))
        self.assertTrue(helper.call_args_list)
        for call in helper.call_args_list:
            self.assertEqual(call.args[0][-2:], ["--pid", str(self.owner["pid"])])
        return proof

    def test_exact_ledger_owner_is_probed_not_worker_ready_child(self):
        self.create_ledger()
        (self.home / "worker-ready").write_text("99999")
        original = self.database.read_bytes()
        proof = self.proof_with_helper()
        self.shim["assert_recovery_identity"](proof, self.owner)
        self.assertEqual(proof["owner"], self.owner)
        self.assertEqual(self.database.read_bytes(), original)

    def test_helper_unavailable_retains_owner_but_fails_identity_proof(self):
        self.create_ledger()
        proof = self.proof_with_helper(unavailable=True)
        self.assertEqual(proof["owner_state"], "unknown")
        # A running row alone cannot distinguish unknown from same.
        self.assertNotEqual(proof["owner_state"], "gone")
        self.assertEqual(self.shim["running_owner"](self.home), self.owner)
        with self.assertRaisesRegex(AssertionError, "manager"):
            self.shim["assert_recovery_identity"](proof, self.owner)

    def test_wrong_fingerprint_fails_identity_proof(self):
        self.create_ledger()
        proof = self.proof_with_helper(start=67891)
        with self.assertRaises(AssertionError):
            self.shim["assert_recovery_identity"](proof, self.owner)

    def test_changed_ledger_owner_fails_identity_proof(self):
        self.create_ledger()
        proof = self.proof_with_helper()
        for changed in ({"id": "another-execution"}, {"pid": 99999},
                        {"process_started_at": 67891}):
            with self.subTest(changed=changed), self.assertRaises(AssertionError):
                self.shim["assert_recovery_identity"](proof, dict(self.owner, **changed))

    def test_locally_visible_owner_is_not_cross_domain_proof(self):
        self.create_ledger()
        live = self.identity.Identity(self.owner["pid"], "live", self.owner["process_started_at"])
        with patch.object(self.identity, "local_identity", return_value=live):
            proof = self.shim["recovery_identity_proof"](self.home, self.identity)
        with self.assertRaisesRegex(AssertionError, "local"):
            self.shim["assert_recovery_identity"](proof, self.owner)

    def test_first_startup_without_ledger_expects_no_prior_worker(self):
        with patch.object(self.identity, "local_identity") as local:
            proof = self.shim["recovery_identity_proof"](self.home, self.identity)
        self.assertEqual(proof, {"owner": None})
        local.assert_not_called()
        self.assertFalse(self.database.exists())
        with self.assertRaises(AssertionError):
            self.shim["assert_recovery_identity"](proof, self.owner)

    def test_completed_ledger_expects_no_prior_worker(self):
        self.create_ledger(status="completed")
        self.assertEqual(self.shim["recovery_identity_proof"](self.home, self.identity),
                         {"owner": None})

    def test_database_errors_are_not_treated_as_first_startup(self):
        for contents in (b"not a SQLite database", b""):
            with self.subTest(contents=contents):
                self.database.write_bytes(contents)
                with self.assertRaises(sqlite3.DatabaseError):
                    self.shim["recovery_identity_proof"](self.home, self.identity)

    def test_missing_fingerprint_column_is_not_masked(self):
        with sqlite3.connect(self.database) as db:
            db.execute("CREATE TABLE executions (id TEXT, pid INTEGER, status TEXT)")
        with self.assertRaises(sqlite3.OperationalError):
            self.shim["recovery_identity_proof"](self.home, self.identity)

    def test_each_replacement_invocation_records_proof_before_unchanged_exec(self):
        self.create_ledger()
        main = self.shim["main"]
        environment = dict(os.environ, HOME=str(self.home), HERMES_HOME=str(self.home),
                           HERMES_MANAGED="true", XDG_RUNTIME_DIR=str(self.home))
        argv = ["gateway.py", "/actual/package/bin/hermes", "gateway", "--test-argument"]
        for invocation in ("b" * 32, "c" * 32):
            marker = self.home / "cron/ticker_heartbeat"
            marker.write_text("stale")
            proof = self.proof_with_helper()
            with patch.dict(os.environ, dict(environment, INVOCATION_ID=invocation)):
                with patch.object(sys, "argv", argv), patch.object(os, "execv") as execute:
                    # Probe semantics use the real identity API above; isolate only
                    # the exec instrumentation so no real Hermes process is started.
                    with patch.dict(main.__globals__, {"recovery_identity_proof": lambda home: proof}):
                        main()
                    execute.assert_called_once_with(argv[1], argv[1:])
            recorded = json.loads((self.home / "gateway-starts" / invocation / "started.json").read_text())
            self.assertEqual(recorded["invocation"], invocation)
            self.assertEqual(recorded["pid"], os.getpid())
            self.shim["assert_recovery_identity"](recorded["recovery_identity"], self.owner)
            self.assertFalse(marker.exists())

    def test_ledger_permission_errors_are_not_treated_as_first_startup(self):
        with patch.object(Path, "stat", side_effect=PermissionError("ledger denied")):
            with self.assertRaises(PermissionError):
                self.shim["running_owner"](self.home)

    def test_multiple_running_owners_are_not_arbitrarily_selected(self):
        self.create_ledger()
        with sqlite3.connect(self.database) as db:
            db.execute("INSERT INTO executions VALUES ('other', 54321, 67890, 'running')")
        with self.assertRaises(AssertionError):
            self.shim["recovery_identity_proof"](self.home, self.identity)


class GatewayShimTests(unittest.TestCase):
    def test_exec_keeps_pid_and_removes_stale_recovery_marker(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            (home / "cron").mkdir()
            marker = home / "cron/ticker_heartbeat"
            marker.write_text("stale")
            target = home / "target"
            target.write_text(
                f"#!{sys.executable}\n"
                "import json, os, sys\n"
                "print(json.dumps({'pid': os.getpid(), 'args': sys.argv[1:]}))\n"
            )
            target.chmod(0o700)
            environment = dict(os.environ, HOME=directory, HERMES_HOME=directory,
                               HERMES_MANAGED="true", XDG_RUNTIME_DIR=directory,
                               INVOCATION_ID="a" * 32)
            with subprocess.Popen(
                [sys.executable, str(Path(__file__).with_name("gateway.py")),
                 str(target), "gateway", "--test-argument"],
                env=environment, cwd=directory, text=True,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            ) as process:
                output, error = process.communicate(timeout=10)
                self.assertEqual(process.returncode, 0, error)
                observed = json.loads(output)
                started = json.loads((home / "gateway-starts" / ("a" * 32) / "started.json").read_text())
                self.assertEqual(observed["pid"], process.pid)
                self.assertEqual(started["pid"], process.pid)
                self.assertEqual(observed["args"], ["gateway", "--test-argument"])
                self.assertEqual(started["cwd"], directory)
                self.assertEqual(started["invocation"], "a" * 32)
                self.assertEqual(started["recovery_identity"], {"owner": None})
                self.assertFalse((home / "cron/executions.db").exists())
                self.assertFalse(marker.exists())


if __name__ == "__main__":
    unittest.main()
