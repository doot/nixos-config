"""Exercise the installed upstream shell probe; only the user bus is mocked."""

import subprocess

import unittest
from unittest.mock import patch

from tools import process_registry as registry

REAL_RUN = subprocess.run


class ProbeTest(unittest.TestCase):
    def setUp(self):
        self.enterContext(patch.object(registry, "_IS_LINUX", True))
        self.enterContext(patch.object(registry, "_SYSTEMD_SCOPE_AVAILABLE", None))
        self.enterContext(patch.object(registry, "_SYSTEMD_SCOPE_PROBED_AT", 0.0))
        self.which = self.enterContext(patch("shutil.which", return_value="systemd-run"))

    def test_probe_executes_upstream_shell_without_path(self):
        calls = []

        def run_scope(argv, **kwargs):
            calls.append(argv)
            command = argv[argv.index("--") + 1:]
            kwargs["env"] = {"PATH": ""}
            return REAL_RUN(command, **kwargs)

        with patch.object(registry.subprocess, "run", side_effect=run_scope):
            self.assertTrue(registry._systemd_run_user_scope_available())
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][1:3], ["--user", "--scope"])
        self.assertEqual(calls[0][calls[0].index("--") + 1:], ["/bin/sh", "-c", "exit 0"])

    def test_failed_scope_stays_unavailable(self):
        failure = subprocess.CompletedProcess([], 1, b"", b"no user bus")
        with patch.object(registry.subprocess, "run", return_value=failure) as run:
            self.assertFalse(registry._systemd_run_user_scope_available())
        run.assert_called_once()

    def test_missing_systemd_run_stays_unavailable(self):
        self.which.return_value = None
        with patch.object(registry.subprocess, "run") as run:
            self.assertFalse(registry._systemd_run_user_scope_available())
        run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
