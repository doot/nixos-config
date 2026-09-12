"""Run inside a worker; writable canaries distinguish isolation from Unix permissions."""

import ctypes
import errno
import json
import os
from pathlib import Path
import sys


def probe_peer(peer: int, outside: Path) -> dict:
    results = {}
    for path in (
        f"/proc/{peer}/root{outside}",
        f"/proc/{peer}/cwd/{outside.name}",
        f"/proc/{peer}/fd/3",
    ):
        try:
            fd = os.open(path, os.O_WRONLY | os.O_APPEND)
        except OSError as error:
            results[path] = error.errno
        else:
            results[path] = 0
            try:
                os.write(fd, b"proc escape\n")
            except OSError as error:
                results[path] = f"open succeeded; write errno {error.errno}"
            finally:
                os.close(fd)
    print(json.dumps({"proc_peer_errnos": results}), flush=True)
    # ProtectProc=invisible may hide a live peer after a Landlock ptrace denial.
    assert all(value in (errno.EACCES, errno.EPERM, errno.ENOENT) for value in results.values()), results
    return results


def probe_cgroup_writes(root: Path, *, denied: bool) -> dict:
    results = {}
    for name in ("cgroup.procs", "cgroup.subtree_control"):
        path = root / name
        path.stat()  # Missing delegation is not evidence of write confinement.
        try:
            fd = os.open(path, os.O_WRONLY)
        except OSError as error:
            results[name] = error.errno
        else:
            os.close(fd)  # Opening tests write authority without moving a process.
            results[name] = 0
    print(json.dumps(results), flush=True)
    expected = (errno.EACCES, errno.EPERM, errno.EROFS) if denied else (0,)
    assert all(value in expected for value in results.values()), results
    return results


def probe(outside: Path, state: Path, *, cgroup_writes: bool = False) -> None:
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

    peer_fixture = json.loads(Path("/run/hermes-test-peer/ready.json").read_text())
    peer = peer_fixture["pid"]
    assert peer > 1, "invalid peer PID"
    assert peer_fixture["uids"] == [os.getuid()] * 4, "peer UID differs from probe"
    pid_namespace = os.readlink("/proc/self/ns/pid")
    assert peer_fixture["pid_namespace"] == pid_namespace, "peer PID namespace differs from probe"
    proc_errnos = probe_peer(peer, outside)

    state.mkdir(exist_ok=True)
    report = {
        "pid": os.getpid(),
        "peer_fixture": peer_fixture,
        "pid_namespace": pid_namespace,
        "proc_peer_errnos": proc_errnos,
        "cgroup": Path("/proc/self/cgroup").read_text(),
        "no_new_privileges": True,
        "capabilities_empty": True,
        "outside_write_denied": True,
        "user_namespace_denied": True,
    }
    if cgroup_writes:
        report["cgroup_write_errnos"] = probe_cgroup_writes(Path("/sys/fs/cgroup"), denied=True)
    (state / "probe.json").write_text(json.dumps(report))
    print(json.dumps(report))


if __name__ == "__main__":
    if sys.argv[1:] == ["cgroup-control"]:
        probe_cgroup_writes(Path("/sys/fs/cgroup"), denied=False)
    else:
        probe(Path(sys.argv[1]), Path(sys.argv[2]))
