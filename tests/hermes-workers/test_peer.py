"""Local fixture controls; no systemd or confinement emulation."""

import importlib.util
import contextlib
import errno
import io
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from probe import probe_peer


class PeerControls(unittest.TestCase):
    def test_real_peer_controls(self):
        helper = Path(__file__).with_name("peer.py")
        self.assertTrue(helper.is_file(), "peer controls are missing")
        spec = importlib.util.spec_from_file_location("peer", helper)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as directory:
            canary = Path(directory) / "worker-canary"
            ready = Path(directory) / "ready.json"
            canary.write_text("canary\n")
            with subprocess.Popen(
                [sys.executable, str(helper), "serve", str(canary), str(ready)],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            ) as peer:
                try:
                    assert peer.stdout is not None
                    self.assertTrue(select.select([peer.stdout], [], [], 5)[0], "peer not ready")
                    self.assertEqual(peer.stdout.readline().strip(), "ready")
                    expected = json.loads(ready.read_text())
                    self.assertEqual(expected["pid"], peer.pid)
                    self.assertEqual(module.check_peer(canary, ready), expected)
                    confined = subprocess.run(
                        ["setpriv", "--no-new-privs", "--landlock-access=fs:write-file", "--",
                         sys.executable, "-B", "-c",
                         "from pathlib import Path; from probe import probe_peer; "
                         "import sys; probe_peer(int(sys.argv[1]), Path(sys.argv[2]))",
                         str(peer.pid), str(canary)],
                        cwd=helper.parent, capture_output=True, text=True, check=True,
                    )
                    denied = json.loads(confined.stdout)["proc_peer_errnos"]
                    self.assertEqual(len(denied), 3)
                    self.assertTrue(all(value in (errno.EACCES, errno.EPERM, errno.ENOENT)
                                        for value in denied.values()))
                    self.assertEqual(module.check_peer(canary, ready), expected)
                    print("real Landlock probe:", denied)
                    stale = dict(expected, starttime=expected["starttime"] + 1)
                    ready.write_text(json.dumps(stale))
                    with self.assertRaisesRegex(AssertionError, "identity"):
                        module.check_peer(canary, ready)
                    ready.write_text(json.dumps(expected))
                    canary.rename(canary.with_suffix(".old"))
                    canary.write_text("replacement\n")
                    with self.assertRaisesRegex(AssertionError, "inode"):
                        module.check_peer(canary, ready)
                    # Root/cwd now resolve to the replacement, but fd 3 still points to the old inode.
                    ready.write_text(json.dumps(dict(expected, canary_inode=module.inode(canary))))
                    with self.assertRaisesRegex(AssertionError, "wrong inode.*fd/3"):
                        module.check_peer(canary, ready)
                    ready.write_text(json.dumps(expected))
                    canary.unlink()
                    with self.assertRaises(FileNotFoundError):
                        module.check_peer(canary, ready)
                    self.assertFalse(canary.exists(), "control recreated missing canary")
                    canary.with_suffix(".old").rename(canary)
                    self.assertEqual(module.check_peer(canary, ready), expected)
                    with contextlib.redirect_stdout(io.StringIO()) as output:
                        with self.assertRaises(AssertionError):
                            probe_peer(peer.pid, canary)
                    self.assertEqual(list(json.loads(output.getvalue())["proc_peer_errnos"].values()), [0, 0, 0])
                    with self.assertRaisesRegex(AssertionError, "escape marker"):
                        module.check_peer(canary, ready)
                    peer.terminate()
                    peer.wait(timeout=5)
                    with self.assertRaises((ProcessLookupError, FileNotFoundError, AssertionError)):
                        module.check_peer(canary, ready)
                    print("real peer: controls pass; stale identity, wrong inode and dead peer fail")
                finally:
                    if peer.poll() is None:
                        peer.terminate()
                        peer.wait(timeout=5)

    def test_proc_errno_allowlist_attempts_every_alias(self):
        # Only errno classification is injected; fixture controls above use real processes and files.
        for errors in ((errno.EACCES, errno.EPERM, errno.ENOENT),
                       (errno.EIO, errno.ENOENT, errno.EACCES),
                       (errno.EROFS, errno.EPERM, errno.EACCES)):
            with self.subTest(errors=errors), patch(
                "probe.os.open", side_effect=[OSError(value, os.strerror(value)) for value in errors]
            ) as opened, contextlib.redirect_stdout(io.StringIO()) as output:
                if errors[0] == errno.EACCES:
                    probe_peer(123, Path("/srv/worker-canary"))
                else:
                    with self.assertRaises(AssertionError):
                        probe_peer(123, Path("/srv/worker-canary"))
                self.assertEqual(opened.call_count, 3)
                self.assertEqual(list(json.loads(output.getvalue())["proc_peer_errnos"].values()), list(errors))
                self.assertTrue(all(not call.args[1] & os.O_CREAT for call in opened.call_args_list))


if __name__ == "__main__":
    unittest.main()
