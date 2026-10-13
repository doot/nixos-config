"""Real process/ledger regressions, with mocked identity/signalling race boundaries.

Run with the installed Hermes interpreter, optionally --source PATCHED_TREE.
Landlock tests run in disposable forked children, never in the test runner.
"""
from contextlib import contextmanager, ExitStack
import ctypes
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import traceback
import unittest
from unittest.mock import Mock, patch

def option(name, default):
    if name not in sys.argv:
        return default
    index = sys.argv.index(name)
    value = sys.argv[index + 1]
    del sys.argv[index:index + 2]
    return value

HELPER = option("--helper", str(Path(__file__).with_name("hermes-recovery-identity.py")))
HELPER_PYTHON = option("--helper-python", sys.executable)

if "--source" in sys.argv:
    index = sys.argv.index("--source")
    source = Path(sys.argv[index + 1])
    del sys.argv[index:index + 2]
    import cron.executions  # initialize the installed package before replacing its modules
    import tools.process_registry
    patched_modules = (
        "gateway.recovery_identity", "gateway.status", "cron.executions",
        "tools.process_registry_checkpoint", "tools.process_registry", "tools.async_delegation",
        "tools.browser_lightpanda", "tools.browser_tool_lifecycle",
    )
    for name in patched_modules:
        path = source / (name.replace(".", "/") + ".py")
        # A partial source tree must not silently test an installed, unpatched module.
        assert path.is_file(), f"Missing patched module: {path}"
        spec = importlib.util.spec_from_file_location(name, path)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        spec.loader.exec_module(module)
        package, attr = name.rsplit(".", 1)
        setattr(sys.modules[package], attr, module)
    for name in patched_modules:
        loaded_path = sys.modules[name].__file__
        assert isinstance(loaded_path, str)
        assert Path(loaded_path).resolve() == (source / (name.replace(".", "/") + ".py")).resolve()

from cron import executions
from gateway import status
from tools import process_registry as registry


def deny_proc_reads():
    """Actual unprivileged kernel denial, with imports and scratch data readable."""
    libc = ctypes.CDLL(None, use_errno=True)
    class Ruleset(ctypes.Structure):
        _fields_ = [("handled_access_fs", ctypes.c_uint64)]
    class PathRule(ctypes.Structure):
        _pack_ = 1
        _fields_ = [("allowed_access", ctypes.c_uint64), ("parent_fd", ctypes.c_int)]
    def checked(result):
        if result < 0:
            raise OSError(ctypes.get_errno(), "Landlock prerequisite failed")
        return result
    rules = Ruleset(4)  # LANDLOCK_ACCESS_FS_READ_FILE
    fd = checked(libc.syscall(444, ctypes.byref(rules), ctypes.sizeof(rules), 0))
    try:
        for path in {"/nix", tempfile.gettempdir(), "/dev"}:
            parent = os.open(path, os.O_PATH | os.O_CLOEXEC)
            try:
                rule = PathRule(4, parent)
                checked(libc.syscall(445, fd, 1, ctypes.byref(rule), 0))
            finally:
                os.close(parent)
        checked(libc.prctl(38, 1, 0, 0, 0))
        checked(libc.syscall(446, fd, 0))
    finally:
        os.close(fd)


class RecoveryTest(unittest.TestCase):
    def setUp(self):
        self.tmp = self.enterContext(tempfile.TemporaryDirectory())
        self.enterContext(patch.object(executions, "EXECUTIONS_FILE", Path(self.tmp) / "executions.db"))
        self.worker = subprocess.Popen([sys.executable, "-I", "-c", "import time; time.sleep(60)"])
        self.addCleanup(self.stop_worker)
        self.start = int(Path(f"/proc/{self.worker.pid}/stat").read_text().rsplit(")", 1)[1].split()[19])

    def stop_worker(self):
        if self.worker.poll() is None:
            self.worker.terminate()
        self.worker.wait(timeout=5)

    def confined(self, fn):
        read_fd, write_fd = os.pipe()
        pid = os.fork()
        if pid == 0:
            os.close(read_fd)
            try:
                deny_proc_reads()
                with self.assertRaises(PermissionError):
                    Path(f"/proc/{self.worker.pid}/stat").read_text()
                fn()
            except BaseException:
                os.write(write_fd, traceback.format_exc().encode())
                os._exit(1)
            os._exit(0)
        os.close(write_fd)
        with os.fdopen(read_fd) as pipe:
            detail = pipe.read()
        _, result = os.waitpid(pid, 0)
        self.assertEqual(result, 0, detail)
        self.assertIsNone(self.worker.poll(), "live positive control died")
        self.assertEqual(self.start, int(Path(f"/proc/{self.worker.pid}/stat").read_text().rsplit(")", 1)[1].split()[19]))

    def test_helper_live_then_proven_absent(self):
        def probe(pid):
            result = subprocess.run([HELPER_PYTHON, "-I", HELPER, "--pid", str(pid)], capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout)
        self.assertEqual(probe(self.worker.pid), {"version": 1, "pid": self.worker.pid, "state": "live", "start_time": self.start})
        self.stop_worker()
        self.assertEqual(probe(self.worker.pid), {"version": 1, "pid": self.worker.pid, "state": "absent", "start_time": None})

    def test_hidden_process_identity_comes_from_manager(self):
        response = subprocess.run([HELPER_PYTHON, "-I", HELPER, "--pid", str(self.worker.pid)], capture_output=True, text=True, check=True)
        def recover():
            from gateway.recovery_identity import get_identity
            with patch("subprocess.run", return_value=response) as transport:
                self.assertIsNone(status.get_process_start_time(self.worker.pid))
                transport.assert_not_called()
                self.assertEqual(get_identity(self.worker.pid).start_time, self.start)
            transport.assert_called_once()
            args, kwargs = transport.call_args
            for flag in ("--user", "--wait", "--pipe", "--collect"):
                self.assertIn(flag, args[0])
            self.assertNotIn("--scope", args[0])
            self.assertEqual(args[0][-2:], ["--pid", str(self.worker.pid)])
            self.assertLessEqual(kwargs["timeout"], 5)
        self.confined(recover)

    def test_gateway_manager_snapshot_cannot_authorize_signalling(self):
        from gateway import recovery_identity as identity

        response = subprocess.CompletedProcess([], 0, json.dumps({
            "version": 1, "pid": self.worker.pid, "state": "live", "start_time": self.start,
        }), "")
        for caller in ("force_stop", "scoped_lock_takeover"):
            with self.subTest(caller=caller), self.inert_signals(), patch.object(
                identity, "local_identity", return_value=identity.Identity(self.worker.pid, "inaccessible"),
            ), patch("subprocess.run", return_value=response) as manager, patch.object(
                status, "_pid_exists", return_value=True,
            ):
                self.assertEqual(identity.owner_state(self.worker.pid, self.start), "same")
                manager.assert_called_once()
                manager.reset_mock()
                if caller == "force_stop":
                    with self.assertRaisesRegex(OSError, "unavailable"):
                        status.terminate_pid(self.worker.pid, force=True, expected_start_time=self.start)
                else:
                    self.assertIsNone(status._terminate_verified_owner(
                        self.worker.pid, self.start, graceful_attempts=0, force_attempts=0,
                    ))
                    self.assertEqual(status._scoped_lock_owner_state(self.worker.pid, self.start), "unknown")
                manager.assert_not_called()

    def test_checkpoint_recovery_never_stops_linux_saved_scope(self):
        from gateway import recovery_identity as identity

        observations = {
            "same": identity.Identity(self.worker.pid, "live", self.start),
            "unknown": identity.Identity(self.worker.pid, "inaccessible"),
            "absent": identity.Identity(self.worker.pid, "absent"),
            "reused": identity.Identity(self.worker.pid, "live", self.start + 1),
        }
        for state, observation in observations.items():
            with self.subTest(state=state), self.inert_signals(), patch.object(
                identity, "get_identity", return_value=observation,
            ), patch.dict(os.environ, {"HERMES_HOME": self.tmp}):
                checkpoint = Path(self.tmp) / "scope-recovery.json"
                entry = {
                    "session_id": "proc_deadbeef", "pid": self.worker.pid,
                    "pid_scope": "host", "host_start_time": self.start,
                    "command": "disposable", "systemd_unit": "hermes-worker-test-only.scope",
                }
                checkpoint.write_text(json.dumps([entry]))
                with patch.object(registry, "CHECKPOINT_PATH", checkpoint):
                    reg = registry.ProcessRegistry()
                    adopted = state in ("same", "unknown")
                    self.assertEqual(reg.recover_from_checkpoint(), int(adopted))
                    self.assertEqual("proc_deadbeef" in reg._running, adopted)
                    if adopted:
                        session = reg._running["proc_deadbeef"]
                        self.assertTrue(session.detached)
                        self.assertIsNone(session.process)
                    reg._write_checkpoint()
                    retained = json.loads(checkpoint.read_text())
                    self.assertEqual(len(retained), 1)
                    for key, value in entry.items():
                        self.assertEqual(retained[0][key], value)
                    reg._running["proc_cafefeed"] = registry.ProcessSession(
                        id="proc_cafefeed", command="unrelated", pid=self.worker.pid,
                        host_start_time=self.start,
                    )
                    reg._write_checkpoint()
                    self.assertEqual({e["session_id"] for e in json.loads(checkpoint.read_text())},
                                     {"proc_deadbeef", "proc_cafefeed"})
                    reg._running.pop("proc_cafefeed")
                    reg._write_checkpoint()
                    self.assertEqual(len(json.loads(checkpoint.read_text())), 1)

    def test_refresh_retains_saved_scope_through_exit_and_restart(self):
        from itertools import product
        from agent.redact import redact_sensitive_text
        from gateway import recovery_identity as identity

        observations = {
            "same": identity.Identity(self.worker.pid, "live", self.start),
            "unknown": identity.Identity(self.worker.pid, "inaccessible"),
            "absent": identity.Identity(self.worker.pid, "absent"),
            "reused": identity.Identity(self.worker.pid, "live", self.start + 1),
        }
        for initial, final, caller, interleave in product(
            ("same", "unknown"), ("absent", "reused"),
            ("get", "poll", "list_sessions", "has_any_active"), (False, True),
        ):
            with self.subTest(initial=initial, final=final, caller=caller, interleave=interleave), self.inert_signals() as (lookup, _), tempfile.TemporaryDirectory(dir=self.tmp) as home, patch.dict(
                os.environ, {"HERMES_HOME": home},
            ), patch.object(identity, "get_identity", return_value=observations[initial]) as inspect:
                checkpoint = Path(home) / "processes.json"
                secret = "sk-disposableCheckpointCanary"
                entry = {
                    "session_id": "proc_deadbeef", "pid": self.worker.pid,
                    "pid_scope": "host", "host_start_time": self.start,
                    "command": f"disposable {secret}",
                    "systemd_unit": "hermes-worker-test-only.scope",
                }
                expected = {**entry, "command": redact_sensitive_text(entry["command"], code_file=True)}
                self.assertNotIn(secret, expected["command"])
                checkpoint.write_text(json.dumps([entry]))
                with patch.object(registry, "CHECKPOINT_PATH", checkpoint):
                    reg = registry.ProcessRegistry()
                    self.assertEqual(reg.recover_from_checkpoint(), 1)
                    session = reg.get(entry["session_id"])
                    self.assertFalse(session.exited)
                    self.assertTrue(session.detached)
                    self.assertIsNone(session.process)
                    self.assertIsNone(session._pty)
                    snapshots = []
                    finish = reg._move_to_finished

                    def checkpoint_before_finish(current):
                        self.assertTrue(current.exited)
                        self.assertIs(reg._running.get(current.id), current)
                        reg._write_checkpoint()
                        snapshots.append(json.loads(checkpoint.read_text()))
                        finish(current)

                    inspect.return_value = observations[final]
                    with patch.object(reg, "_move_to_finished", side_effect=checkpoint_before_finish if interleave else finish):
                        args = (session.id,) if caller in ("get", "poll") else ()
                        getattr(reg, caller)(*args)
                    self.assertTrue(session.exited)
                    self.assertIsNone(session.exit_code)
                    self.assertNotIn(session.id, reg._running)
                    self.assertIs(reg._finished.get(session.id), session)
                    self.assertFalse(reg.has_any_active())
                    self.assertEqual(reg.poll(session.id)["status"], "exited")
                    snapshots.append(json.loads(checkpoint.read_text()))
                    for snapshot in snapshots:
                        self.assertEqual(len(snapshot), 1, "refresh discarded the saved scope")
                        for key, value in expected.items():
                            self.assertEqual(snapshot[0][key], value)
                    reg._finished.clear()  # Scope retention must outlive in-memory receipts.
                    for extra in (None, [expected, expected], None):
                        reg._write_checkpoint(extra_entries=extra)
                        saved = json.loads(checkpoint.read_text())
                        self.assertEqual(len(saved), 1)
                        for key, value in expected.items():
                            self.assertEqual(saved[0][key], value)
                        self.assertNotIn(secret, checkpoint.read_text())
                    restarted = registry.ProcessRegistry()
                    self.assertEqual(restarted.recover_from_checkpoint(), 0)
                    self.assertFalse(restarted.has_any_active())
                    restarted._write_checkpoint()
                    saved = json.loads(checkpoint.read_text())
                    self.assertEqual(len(saved), 1)
                    for key, value in expected.items():
                        self.assertEqual(saved[0][key], value)
                    lookup.assert_not_called()

    def test_nonlinux_checkpoint_keeps_existing_scope_cleanup(self):
        for stopped in (True, False):
            with self.subTest(stopped=stopped), patch.object(registry, "_IS_LINUX", False), patch.object(
                registry.ProcessRegistry, "_host_pid_is_ours", return_value=False,
            ), patch.object(registry.ProcessRegistry, "_is_host_pid_alive", return_value=False), patch.object(
                registry, "_stop_systemd_unit", return_value=stopped,
            ) as stop:
                checkpoint = Path(self.tmp) / "nonlinux-scope.json"
                entry = {"session_id": "proc_deadbeef", "pid": self.worker.pid,
                         "systemd_unit": "hermes-worker-test-only.scope"}
                checkpoint.write_text(json.dumps([entry]))
                with patch.object(registry, "CHECKPOINT_PATH", checkpoint):
                    self.assertEqual(registry.ProcessRegistry().recover_from_checkpoint(), 0)
                stop.assert_called_once_with(entry["systemd_unit"])
                self.assertEqual(json.loads(checkpoint.read_text()), [] if stopped else [entry])

    def test_owner_without_fingerprint_is_not_proven_dead(self):
        self.assertTrue(executions._owner_is_live(self.worker.pid, None))

    def test_unreadable_background_checkpoint_stays_active(self):
        checkpoint = Path(self.tmp) / "processes.json"
        checkpoint.write_text(json.dumps([{"session_id": "proc_deadbeef", "pid": self.worker.pid, "pid_scope": "host", "host_start_time": self.start, "command": "disposable"}]))
        self.enterContext(patch.object(registry, "CHECKPOINT_PATH", checkpoint))
        def recover():
            reg = registry.ProcessRegistry()
            with patch("subprocess.run", side_effect=OSError("test: no user bus")):
                self.assertEqual(reg.recover_from_checkpoint(), 1)
                self.assertEqual(reg.poll("proc_deadbeef")["status"], "running")
                self.assertTrue(reg.has_any_active())
                self.assertEqual(reg.kill_process("proc_deadbeef")["status"], "error")
                self.assertFalse(reg.get("proc_deadbeef").exited)
            self.assertEqual(len(json.loads(checkpoint.read_text())), 1)
        self.confined(recover)

    def test_legacy_checkpoint_does_not_invent_spawn_identity(self):
        checkpoint = Path(self.tmp) / "legacy.json"
        checkpoint.write_text(json.dumps([{"session_id": "proc_deadbeef", "pid": self.worker.pid, "command": "disposable"}]))
        self.enterContext(patch.object(registry, "CHECKPOINT_PATH", checkpoint))
        reg = registry.ProcessRegistry()
        self.assertEqual(reg.recover_from_checkpoint(), 1)
        self.assertIsNone(reg.get("proc_deadbeef").host_start_time)
        self.assertIsNone(json.loads(checkpoint.read_text())[0]["host_start_time"])
        self.assertEqual(reg.kill_process("proc_deadbeef")["status"], "error")
        self.assertIsNone(self.worker.poll())

    def test_termination_requires_spawn_fingerprint(self):
        with self.assertRaises(OSError):
            registry.ProcessRegistry._terminate_host_pid(self.worker.pid, None)
        self.assertIsNone(self.worker.poll())

    @contextmanager
    def recovered_kill_fixture(self):
        """Keep real recovery/state writes, but contain even a regressed kill."""
        import psutil
        import signal

        with ExitStack() as stack:
            home = Path(stack.enter_context(tempfile.TemporaryDirectory(dir=self.tmp)))
            stack.enter_context(patch.dict(os.environ, {"HERMES_HOME": str(home)}))
            checkpoint = home / "processes.json"
            stack.enter_context(patch.object(registry, "CHECKPOINT_PATH", checkpoint))
            parent = Mock(name="numeric_pid_replacement", pid=self.worker.pid)
            child = Mock(name="replacement_descendant")
            parent.children.return_value = [child]
            parent.is_running.return_value = child.is_running.return_value = False
            numeric_lookup = stack.enter_context(patch.object(psutil, "Process", return_value=parent))
            signals = {
                "scope stop": stack.enter_context(patch.object(registry, "_stop_systemd_unit", return_value=True)),
                "numeric signal": stack.enter_context(patch.object(os, "kill")),
                "group signal": stack.enter_context(patch.object(os, "killpg")),
                "pidfd signal": stack.enter_context(patch.object(signal, "pidfd_send_signal")),
                "parent terminate": parent.terminate,
                "parent kill": parent.kill,
                "child terminate": child.terminate,
                "child kill": child.kill,
            }
            checkpoint.write_text(json.dumps([{
                "session_id": "proc_deadbeef", "pid": self.worker.pid,
                "pid_scope": "host", "host_start_time": self.start,
                "command": "disposable", "systemd_unit": "hermes-worker-test-only.scope",
            }]))
            reg = registry.ProcessRegistry()
            self.assertEqual(reg.recover_from_checkpoint(), 1)
            session = reg.get("proc_deadbeef")
            self.assertIsNotNone(session)
            self.assertTrue(session.detached)
            self.assertIsNone(session.process)
            self.assertIsNone(session._pty)
            self.assertIsNone(session.env_ref)
            yield reg, session, checkpoint, numeric_lookup, signals
        self.assertIsNone(self.worker.poll(), "disposable positive control was signalled")

    def assert_kill_refused_and_retained(self, result, reg, session, checkpoint, signals):
        for name, sink in signals.items():
            with self.subTest(signal=name):
                sink.assert_not_called()
        self.assertEqual(result["status"], "error", result)
        self.assertFalse(session.exited)
        self.assertIsNone(session.exit_code)
        self.assertIs(reg._running.get(session.id), session)
        self.assertNotIn(session.id, reg._finished)
        self.assertNotIn(session.id, reg._completion_consumed)
        self.assertFalse(session._completion_event.is_set())
        self.assertTrue(reg.completion_queue.empty())
        self.assertTrue(reg.has_any_active())
        self.assertEqual(reg.poll(session.id)["status"], "running")
        entries = json.loads(checkpoint.read_text())
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]["session_id"], session.id)
        self.assertEqual(entries[0]["pid"], self.worker.pid)
        self.assertEqual(entries[0]["host_start_time"], self.start)
        self.assertEqual(entries[0]["systemd_unit"], session.systemd_unit)
        self.assertFalse((checkpoint.parent / "logs" / "process-results" / f"{session.id}.json").exists())

    def test_kill_identity_same_same_unknown_retains_checkpoint(self):
        from gateway import recovery_identity as identity

        live = identity.Identity(self.worker.pid, "live", self.start)
        unknown = identity.Identity(self.worker.pid, "inaccessible")
        # Identity sequences model denial during refresh or later termination checks.
        for same_reads in (2, 3):
            with self.subTest(same_reads=same_reads), patch.object(identity, "get_identity", return_value=live) as inspect:
                with self.recovered_kill_fixture() as (reg, session, checkpoint, lookup, signals):
                    observations = []
                    def observe(pid):
                        value = live if len(observations) < same_reads else unknown
                        observations.append(value)
                        return value
                    inspect.side_effect = observe
                    # Do not replace kill_process, _signal_kill, _terminate_host_pid
                    # or owner_state: the candidate's real decisions are tested.
                    result = reg.kill_process(session.id)
                    self.assertTrue(observations, "kill never checked the recovered identity")
                    for call in inspect.call_args_list:
                        self.assertEqual(call.args, (self.worker.pid,))
                    self.assert_kill_refused_and_retained(result, reg, session, checkpoint, signals)
                    lookup.assert_not_called()

    def test_manager_snapshot_cannot_authorize_reused_numeric_pid(self):
        import psutil
        from gateway import recovery_identity as identity

        response = subprocess.CompletedProcess([], 0, json.dumps({
            "version": 1, "pid": self.worker.pid, "state": "live", "start_time": self.start,
        }), "")
        for access_denied in (False, True):
            with self.subTest(access_denied=access_denied), patch.object(
                identity, "local_identity", return_value=identity.Identity(self.worker.pid, "inaccessible"),
            ), patch("subprocess.run", return_value=response) as manager:
                with self.recovered_kill_fixture() as (reg, session, checkpoint, lookup, signals):
                    self.assertGreater(manager.call_count, 0, "manager fallback was not exercised")
                    for call in manager.call_args_list:
                        self.assertEqual(call.args[0][-2:], ["--pid", str(self.worker.pid)])
                    replacement = lookup.return_value
                    def reuse_after_snapshot(pid):
                        self.assertEqual(pid, self.worker.pid)
                        # Deterministic interleaving: the original exits AFTER
                        # the final manager reply, BEFORE a numeric lookup. This
                        # object represents its replacement, never a real PID.
                        if access_denied:
                            raise psutil.AccessDenied(pid)
                        return replacement
                    lookup.side_effect = reuse_after_snapshot
                    # Real get_identity parses manager JSON; real owner_state and
                    # the real patched termination function decide what to do.
                    result = reg.kill_process(session.id)
                    self.assert_kill_refused_and_retained(result, reg, session, checkpoint, signals)
                    lookup.assert_not_called()

    def test_recovered_already_exited_kill_refuses_before_mutations(self):
        from gateway import recovery_identity as identity

        live = identity.Identity(self.worker.pid, "live", self.start)
        gone = identity.Identity(self.worker.pid, "absent")
        for already_exited in (False, True):
            with self.subTest(already_exited=already_exited), patch.object(identity, "get_identity", return_value=live) as inspect:
                with self.recovered_kill_fixture() as (reg, session, checkpoint, lookup, signals):
                    # Exercise both refresh-to-exited and pre-existing exited state.
                    session.exited = already_exited
                    session.exit_code = 0 if already_exited else None
                    session.output_buffer = "unconsumed recovered output"
                    before = checkpoint.read_bytes()
                    inspect.return_value = gone
                    with patch.object(reg, "_write_checkpoint", wraps=reg._write_checkpoint) as write, patch.object(
                        reg, "_move_to_finished", wraps=reg._move_to_finished,
                    ) as finish, patch.object(registry, "_output_tail", wraps=registry._output_tail) as output:
                        result = reg.kill_process(session.id)
                    self.assertEqual(result["status"], "error", result)
                    self.assertIn("original runtime handle", result["error"])
                    write.assert_not_called()
                    finish.assert_not_called()
                    output.assert_not_called()
                    lookup.assert_not_called()
                    for name, sink in signals.items():
                        with self.subTest(signal=name):
                            sink.assert_not_called()
                    self.assertEqual(checkpoint.read_bytes(), before)
                    self.assertIs(reg._running.get(session.id), session)
                    self.assertNotIn(session.id, reg._finished)
                    self.assertNotIn(session.id, reg._completion_consumed)
                    self.assertEqual(session.exited, already_exited)
                    self.assertEqual(session.exit_code, 0 if already_exited else None)
                    self.assertEqual(session.output_buffer, "unconsumed recovered output")
                    self.assertFalse(session._completion_event.is_set())
                    self.assertTrue(reg.completion_queue.empty())

    def test_original_popen_owned_child_public_kill_still_works(self):
        import signal

        self.enterContext(patch.dict(os.environ, {"HERMES_HOME": self.tmp}))
        checkpoint = Path(self.tmp) / "owned.json"
        self.enterContext(patch.object(registry, "CHECKPOINT_PATH", checkpoint))
        reg = registry.ProcessRegistry()
        session = registry.ProcessSession(
            id="proc_cafefeed", command="disposable owned child", pid=self.worker.pid,
            process=self.worker, host_start_time=self.start, output_buffer="owned output",
        )
        reg._running[session.id] = session
        reg._write_checkpoint()
        self.assertIsNone(self.worker.poll())
        with patch.object(registry, "_stop_systemd_unit") as scope, patch.object(
            registry.ProcessRegistry, "_daemon_term_grace_seconds", return_value=0.1,
        ):
            result = reg.kill_process(session.id)
        self.assertEqual(result["status"], "killed", result)
        self.assertEqual(self.worker.wait(timeout=5), -signal.SIGTERM)
        scope.assert_not_called()
        self.assertEqual(result["output"], "owned output")
        self.assertTrue(session.exited)
        self.assertEqual(session.completion_reason, "killed")
        self.assertIs(reg._finished.get(session.id), session)
        self.assertNotIn(session.id, reg._running)
        self.assertEqual(json.loads(checkpoint.read_text()), [])

    @contextmanager
    def inert_signals(self):
        """Mock every signal sink around synthetic PID/identity observations."""
        import psutil
        import signal

        with ExitStack() as stack:
            parent = Mock(name="synthetic_process", pid=self.worker.pid)
            child = Mock(name="synthetic_descendant")
            parent.children.return_value = [child]
            parent.is_running.return_value = child.is_running.return_value = False
            lookup = stack.enter_context(patch.object(psutil, "Process", return_value=parent))
            sinks = [parent.terminate, parent.kill, child.terminate, child.kill]
            for obj, attr in ((os, "kill"), (os, "killpg"), (signal, "pidfd_send_signal"),
                              (registry, "_stop_systemd_unit"), (self.worker, "terminate"), (self.worker, "kill")):
                sinks.append(stack.enter_context(patch.object(obj, attr)))
            try:
                yield lookup, sinks
            finally:
                # Retention assertions can fail; still prove no signal escaped.
                for sink in sinks:
                    with self.subTest(signal=sink._extract_mock_name()):
                        sink.assert_not_called()
                self.assertIsNone(self.worker.poll(), "a refusal signalled the positive control")

    def test_termination_missing_or_mismatched_original_handle_refuses(self):
        from gateway import recovery_identity as identity

        wrong_handle = Mock(spec=subprocess.Popen, pid=self.worker.pid + 1)
        for process in (None, wrong_handle):
            with self.subTest(handle="missing" if process is None else "mismatched"), self.inert_signals() as (lookup, _):
                with patch.object(identity, "local_identity", wraps=identity.local_identity) as local, patch(
                    "subprocess.run", side_effect=AssertionError("unexpected manager launch"),
                ) as manager:
                    with self.assertRaisesRegex(OSError, "original runtime handle"):
                        registry.ProcessRegistry._terminate_host_pid(self.worker.pid, self.start, process=process)
                lookup.assert_not_called()
                local.assert_not_called()
                manager.assert_not_called()
        wrong_handle.poll.assert_not_called()
        wrong_handle.terminate.assert_not_called()
        wrong_handle.kill.assert_not_called()

    def test_original_popen_local_unknown_refuses_without_manager_fallback(self):
        from gateway import recovery_identity as identity

        with self.inert_signals() as (lookup, _), patch.object(
            identity, "local_identity", return_value=identity.Identity(self.worker.pid, "inaccessible"),
        ) as local, patch("subprocess.run", side_effect=AssertionError("unexpected manager launch")) as manager:
            with self.assertRaisesRegex(OSError, "inaccessible"):
                registry.ProcessRegistry._terminate_host_pid(self.worker.pid, self.start, process=self.worker)
            local.assert_called_once_with(self.worker.pid)
            lookup.assert_not_called()
            manager.assert_not_called()

    @contextmanager
    def browser_records(self):
        from types import SimpleNamespace
        from tools import browser_lightpanda as lightpanda
        from tools import browser_tool_lifecycle as lifecycle

        with ExitStack() as stack:
            home = Path(stack.enter_context(tempfile.TemporaryDirectory(dir=self.tmp)))
            stack.enter_context(patch.object(lightpanda, "_state_dir", return_value=home))
            stack.enter_context(patch.object(lightpanda, "_servers", {}))
            # Avoid loading the browser facade/atexit reaper: only real cleanup
            # functions below run, over these exact disposable records.
            stack.enter_context(patch.object(lifecycle, "_bt", SimpleNamespace(
                logger=Mock(), BROWSER_ORPHAN_GRACE_SECONDS=60,
            )))
            record = home / "hermes_test.json"
            record.write_text(json.dumps({
                "pid": self.worker.pid, "port": 9222, "owner_pid": os.getpid(),
                "start_time": self.start,
            }))
            socket_dir = home / "agent-browser-hermes_test"
            socket_dir.mkdir()
            (socket_dir / "hermes_test.pid").write_text(str(self.worker.pid))
            (socket_dir / "retention-canary").write_text("keep retry state")
            yield lightpanda, lifecycle, record, socket_dir

    def test_lightpanda_orphan_refused_termination_retains_record(self):
        with self.browser_records() as (lp, _, record, _), self.inert_signals() as (lookup, _):
            proc = lookup.return_value
            proc.name.return_value = "lightpanda"
            proc.cmdline.return_value = ["lightpanda", "serve", "--port", "9222"]
            before = record.read_bytes()
            with patch.object(registry.ProcessRegistry, "_terminate_host_pid", wraps=registry.ProcessRegistry._terminate_host_pid) as terminate:
                self.assertEqual(lp.reap_orphaned_lightpanda(), 0)
            terminate.assert_not_called()
            lookup.assert_not_called()
            self.assertTrue(record.exists(), "refused Lightpanda termination discarded its retry record")
            self.assertEqual(record.read_bytes(), before)

    def test_lightpanda_orphan_unknown_identity_retains_record(self):
        import psutil
        from gateway import recovery_identity as identity

        for boundary in ("process_identity_denied", "start_time_unknown"):
            with self.subTest(boundary=boundary), self.browser_records() as (lp, _, record, _), self.inert_signals() as (lookup, _):
                proc = lookup.return_value
                proc.name.return_value = "lightpanda"
                proc.cmdline.return_value = ["lightpanda", "serve", "--port", "9222"]
                if boundary == "process_identity_denied":
                    proc.name.side_effect = psutil.AccessDenied(self.worker.pid)
                before = record.read_bytes()
                with patch.object(identity, "local_identity", return_value=identity.Identity(self.worker.pid, "inaccessible")) as local, patch(
                    "subprocess.run", side_effect=OSError("test: no user bus"),
                ) as manager, patch.object(registry.ProcessRegistry, "_terminate_host_pid", wraps=registry.ProcessRegistry._terminate_host_pid) as terminate:
                    self.assertEqual(lp.reap_orphaned_lightpanda(), 0)
                self.assertTrue(record.exists(), f"{boundary}: unknown identity discarded its retry record")
                self.assertEqual(record.read_bytes(), before)
                terminate.assert_not_called()
                lookup.assert_not_called()
                local.assert_called_once_with(self.worker.pid)
                manager.assert_called_once()

    def test_lightpanda_pid_only_orphan_removes_only_proven_gone(self):
        from gateway import recovery_identity as identity

        for fingerprint in (self.start, None):
            for state, current in (("live", self.start), ("live", self.start + 1),
                                   ("inaccessible", None), ("absent", None)):
                with self.subTest(fingerprint=fingerprint, state=state, current=current), self.browser_records() as (lp, _, record, _), self.inert_signals() as (lookup, _):
                    data = {"pid": self.worker.pid, "owner_pid": os.getpid()}
                    if fingerprint is not None:
                        data["start_time"] = fingerprint
                    record.write_text(json.dumps(data))
                    before = record.read_bytes()
                    with patch.object(identity, "get_identity", return_value=identity.Identity(self.worker.pid, state, current)), patch.object(
                        registry.ProcessRegistry, "_terminate_host_pid", wraps=registry.ProcessRegistry._terminate_host_pid,
                    ) as terminate:
                        self.assertEqual(lp.reap_orphaned_lightpanda(), 0)
                    gone = state == "absent" or (state == "live" and fingerprint is not None and current != fingerprint)
                    self.assertEqual(record.exists(), not gone)
                    if not gone:
                        self.assertEqual(record.read_bytes(), before)
                    terminate.assert_not_called()
                    lookup.assert_not_called()

    def test_nonlinux_lightpanda_orphan_keeps_existing_cleanup(self):
        with self.browser_records() as (lp, _, record, _), self.inert_signals() as (lookup, _):
            proc = lookup.return_value
            proc.name.return_value = "lightpanda"
            proc.cmdline.return_value = ["lightpanda", "serve", "--port", "9222"]
            proc.create_time.return_value = self.start / 100
            with patch.object(sys, "platform", "darwin"), patch.object(lp, "_tree_kill") as kill:
                self.assertEqual(lp.reap_orphaned_lightpanda(), 1)
            kill.assert_called_once_with(self.worker.pid, self.start)
            self.assertFalse(record.exists())

    def test_browser_orphan_refused_termination_retains_socket_dir(self):
        with self.browser_records() as (_, lifecycle, _, socket_dir), self.inert_signals() as (lookup, _):
            proc = lookup.return_value
            proc.name.return_value = "agent-browser"
            proc.cmdline.return_value = ["agent-browser", str(socket_dir)]
            before = {path.name: path.read_bytes() for path in socket_dir.iterdir()}
            with patch.object(status, "_pid_exists", return_value=True), patch.object(
                registry.ProcessRegistry, "_terminate_host_pid", wraps=registry.ProcessRegistry._terminate_host_pid,
            ) as terminate:
                self.assertFalse(lifecycle._reap_socket_dir(str(socket_dir), "hermes_test", set()))
            terminate.assert_called_once_with(self.worker.pid, self.start)
            self.assertTrue(socket_dir.is_dir(), "refused browser termination discarded its socket directory")
            self.assertEqual({path.name: path.read_bytes() for path in socket_dir.iterdir()}, before)

    def test_browser_orphan_unknown_identity_retains_socket_dir(self):
        import psutil
        from gateway import recovery_identity as identity

        for boundary in ("process_identity_denied", "session_binding_denied", "start_time_unknown"):
            with self.subTest(boundary=boundary), self.browser_records() as (_, lifecycle, _, socket_dir), self.inert_signals() as (lookup, _):
                proc = lookup.return_value
                proc.name.return_value = "agent-browser"
                proc.cmdline.return_value = ["agent-browser", str(socket_dir)]
                if boundary == "process_identity_denied":
                    proc.name.side_effect = psutil.AccessDenied(self.worker.pid)
                elif boundary == "session_binding_denied":
                    proc.cmdline.return_value = ["agent-browser"]
                    proc.environ.side_effect = psutil.AccessDenied(self.worker.pid)
                before = {path.name: path.read_bytes() for path in socket_dir.iterdir()}
                with patch.object(status, "_pid_exists", return_value=True), patch.object(
                    identity, "local_identity", return_value=identity.Identity(self.worker.pid, "inaccessible"),
                ), patch("subprocess.run", side_effect=OSError("test: no user bus")), patch.object(
                    registry.ProcessRegistry, "_terminate_host_pid", wraps=registry.ProcessRegistry._terminate_host_pid,
                ) as terminate:
                    self.assertFalse(lifecycle._reap_socket_dir(str(socket_dir), "hermes_test", set()))
                self.assertGreater(lookup.call_count, 0, "identity guard was not exercised")
                terminate.assert_not_called()
                self.assertTrue(socket_dir.is_dir(), f"{boundary}: unknown identity discarded its socket directory")
                self.assertEqual({path.name: path.read_bytes() for path in socket_dir.iterdir()}, before)

    def test_live_lightpanda_stop_passes_original_popen(self):
        import signal

        with self.browser_records() as (lp, _, record, _):
            server = lp.LightpandaServer("hermes_test", 9222, self.worker, str(record.with_suffix(".log")), self.start)
            lp._servers[server.session_name] = server
            lp._write_record(server)
            self.assertTrue(server.is_alive())
            with patch.object(registry.ProcessRegistry, "_terminate_host_pid", wraps=registry.ProcessRegistry._terminate_host_pid) as terminate, patch.object(
                registry.ProcessRegistry, "_daemon_term_grace_seconds", return_value=0.1,
            ), patch.object(lp, "_terminate", side_effect=AssertionError("unexpected unguarded fallback")) as fallback:
                lp.stop_lightpanda(server.session_name)
            terminate.assert_called_once_with(self.worker.pid, expected_start=self.start, process=self.worker)
            fallback.assert_not_called()
            self.assertEqual(self.worker.wait(timeout=5), -signal.SIGTERM)
            self.assertNotIn(server.session_name, lp._servers)
            self.assertFalse(record.exists())

    def test_unreadable_async_owner_emits_no_recovery_completion(self):
        from tools import async_delegation as background
        self.enterContext(patch.dict(os.environ, {"HERMES_HOME": self.tmp}))
        background._persist_dispatch({"delegation_id": "disposable", "dispatched_at": 1.0})
        with background._transaction() as conn:
            conn.execute("UPDATE async_delegations SET owner_pid=?, owner_started_at=?", (self.worker.pid, self.start))
        def recover():
            with patch("subprocess.run", side_effect=OSError("test: no user bus")):
                self.assertEqual(background.recover_abandoned_delegations(), 0)
            with background._transaction() as conn:
                self.assertEqual(conn.execute("SELECT state,event_json FROM async_delegations").fetchone(), ("running", None))
        self.confined(recover)

    def test_helper_rejects_invalid_pid_arguments(self):
        for value in ("0", "-1", "01", "1/../../self", "true", "2147483648"):
            with self.subTest(value=value):
                result = subprocess.run([HELPER_PYTHON, "-I", HELPER, "--pid", value], capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, "")

    def test_local_denial_is_typed_inaccessible(self):
        from gateway.recovery_identity import local_identity
        def inspect():
            result = local_identity(self.worker.pid)
            self.assertEqual((result.state, result.start_time), ("inaccessible", None))
        self.confined(inspect)

    def test_wrong_fingerprint_proves_previous_owner_gone(self):
        self.assertTrue(executions._owner_is_live(self.worker.pid, self.start))
        self.assertFalse(executions._owner_is_live(self.worker.pid, self.start + 1))
        self.assertFalse(registry.ProcessRegistry._host_pid_is_ours(self.worker.pid, self.start + 1))
        self.assertFalse(registry.ProcessRegistry._host_pid_is_ours(self.worker.pid, None))
        self.stop_worker()
        self.assertFalse(executions._owner_is_live(self.worker.pid, self.start))

    def test_failed_manager_protocol_cannot_prove_death(self):
        from gateway.recovery_identity import get_identity
        valid = {"version": 1, "pid": self.worker.pid, "state": "live", "start_time": self.start}
        bodies = ["", "not-json", "[]", "x" * 1025]
        for changes in ({"pid": self.worker.pid + 1}, {"pid": True}, {"version": True}, {"version": 2}, {"state": "dead"}, {"start_time": None}, {"start_time": True}, {"start_time": -1}, {"state": "absent"}, {"extra": 1}):
            bodies.append(json.dumps(valid | changes))
        responses = [subprocess.CompletedProcess([], 0, body, "") for body in bodies]
        responses.append(subprocess.CompletedProcess([], 1, json.dumps(valid), "denied"))
        def inspect():
            for response in responses:
                with self.subTest(response=response), patch("subprocess.run", return_value=response) as transport:
                    self.assertEqual(get_identity(self.worker.pid).state, "inaccessible")
                    transport.assert_called_once()
            with patch("subprocess.run", side_effect=subprocess.TimeoutExpired("systemd-run", 4)) as transport:
                self.assertEqual(get_identity(self.worker.pid).state, "inaccessible")
                transport.assert_called_once()
        self.confined(inspect)

    def test_inaccessible_live_owner_does_not_recover(self):
        record = executions.create_execution("disposable", source="test")
        with executions._transaction() as conn:
            conn.execute("UPDATE executions SET process_id='previous-gateway', pid=?, process_started_at=?, status='running' WHERE id=?", (self.worker.pid, self.start, record["id"]))
        def recover():
            # A missing manager must not turn an unreadable live owner into death.
            with patch("subprocess.run", side_effect=OSError("test: no user bus")):
                self.assertEqual(executions.recover_interrupted_executions(), 0)
            self.assertEqual(executions.get_execution(record["id"])["status"], "running")
        self.confined(recover)


if __name__ == "__main__":
    unittest.main()
