"""Run inside a worker; writable canaries distinguish isolation from Unix permissions."""

import ctypes
import errno
import json
import os
from pathlib import Path
import sys


def probe(outside: Path, state: Path) -> None:
    status = dict(
        line.split(":", 1) for line in Path("/proc/self/status").read_text().splitlines()
    )
    assert status["NoNewPrivs"].strip() == "1", "NoNewPrivileges was lost"
    for field in ("CapInh", "CapPrm", "CapEff", "CapBnd", "CapAmb"):
        assert int(status[field], 16) == 0, f"{field} was not empty"

    assert outside.stat().st_mode & 0o002, "canary must be writable without the sandbox"
    try:
        with outside.open("a") as target:
            target.write("sandbox escaped\n")
    except OSError as error:
        assert error.errno in (errno.EROFS, errno.EACCES, errno.EPERM), error
    else:
        raise AssertionError("worker wrote outside its permitted state directory")

    libc = ctypes.CDLL(None, use_errno=True)
    assert libc.unshare(0x10000000) == -1, "worker created a user namespace"
    assert ctypes.get_errno() == errno.EPERM, "unexpected unshare failure"

    peer_file = Path("/run/hermes-test-peer.pid")
    if peer_file.exists():
        peer = int(peer_file.read_text())
        for path in (f"/proc/{peer}/root/srv/worker-canary", f"/proc/{peer}/cwd/worker-canary", f"/proc/{peer}/fd/3"):
            try:
                with open(path, "a") as target:
                    target.write("proc escape\n")
            except PermissionError:
                pass
            else:
                raise AssertionError(f"worker escaped through {path}")

    state.mkdir(exist_ok=True)
    report = {
        "pid": os.getpid(),
        "cgroup": Path("/proc/self/cgroup").read_text(),
        "no_new_privileges": True,
        "capabilities_empty": True,
        "outside_write_denied": True,
        "user_namespace_denied": True,
    }
    (state / "probe.json").write_text(json.dumps(report))
    print(json.dumps(report))


if __name__ == "__main__":
    probe(Path(sys.argv[1]), Path(sys.argv[2]))
