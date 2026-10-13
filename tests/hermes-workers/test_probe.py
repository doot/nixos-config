"""Local contract tests; real cgroup delegation is covered only by the VM."""

import contextlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import probe


class CgroupWriteProbeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for name in ("cgroup.procs", "cgroup.subtree_control"):
            (self.root / name).touch()

    def test_positive_control_opens_both_existing_targets(self):
        with contextlib.redirect_stdout(io.StringIO()):
            result = probe.probe_cgroup_writes(self.root, denied=False)
        self.assertEqual(result, {"cgroup.procs": 0, "cgroup.subtree_control": 0})

    def test_unconfined_write_is_not_reported_as_a_denial(self):
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(AssertionError):
            probe.probe_cgroup_writes(self.root, denied=True)

    def test_missing_target_is_not_reported_as_a_denial(self):
        (self.root / "cgroup.procs").unlink()
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(FileNotFoundError):
            probe.probe_cgroup_writes(self.root, denied=True)

    def test_real_landlock_denies_both_existing_targets(self):
        code = "from pathlib import Path; from probe import probe_cgroup_writes; "
        code += "probe_cgroup_writes(Path(" + repr(str(self.root)) + "), denied=True)"
        result = subprocess.run(
            ["setpriv", "--no-new-privs", "--landlock-access=fs:write-file", "--",
             sys.executable, "-c", code],
            cwd=Path(__file__).parent, text=True, capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(set(json.loads(result.stdout)), {"cgroup.procs", "cgroup.subtree_control"})


if __name__ == "__main__":
    unittest.main()
