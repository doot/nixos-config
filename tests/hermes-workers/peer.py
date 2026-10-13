"""Unconfined same-UID peer and positive controls for the worker VM test."""

import json
import os
from pathlib import Path
import sys
import time


def identity(pid):
    assert pid > 1, "invalid peer PID"
    os.kill(pid, 0)
    proc = Path(f"/proc/{pid}")
    fields = (proc / "stat").read_text().rsplit(")", 1)[1].split()
    assert fields[0] not in ("Z", "X"), "peer is dead"
    status = dict(line.split(":", 1) for line in (proc / "status").read_text().splitlines())
    return {
        "pid": pid,
        "starttime": int(fields[19]),
        "uids": [int(uid) for uid in status["Uid"].split()],
        "pid_namespace": os.readlink(proc / "ns/pid"),
    }


def inode(path):
    stat = os.stat(path)
    return [stat.st_dev, stat.st_ino]


def check_peer(canary, ready):
    expected = json.loads(ready.read_text())
    pid = expected["pid"]
    observed = identity(pid)
    assert observed == {key: expected[key] for key in observed}, "peer identity changed"
    assert observed["uids"] == [os.getuid()] * 4, "peer UID differs from control"
    assert observed["pid_namespace"] == os.readlink("/proc/self/ns/pid"), "PID namespace differs"
    assert inode(canary) == expected["canary_inode"], "canonical canary inode changed"
    for path in (
        f"/proc/{pid}/root{canary}",
        f"/proc/{pid}/cwd/{canary.name}",
        f"/proc/{pid}/fd/3",
    ):
        # Never create a missing canary or accept an alias to a different file.
        fd = os.open(path, os.O_WRONLY | os.O_APPEND)
        try:
            stat = os.fstat(fd)
            assert [stat.st_dev, stat.st_ino] == inode(canary) == expected["canary_inode"], f"wrong inode: {path}"
            assert os.write(fd, b"control\n") == len(b"control\n")
        finally:
            os.close(fd)
    assert identity(pid) == observed, "peer identity changed during controls"
    text = canary.read_text()
    assert "proc escape" not in text and "sandbox escaped" not in text, "escape marker in canary"
    return expected


def serve(canary, ready):
    fd = os.open(canary, os.O_RDWR)
    os.dup2(fd, 3)
    if fd != 3:
        os.close(fd)
    os.chdir(canary.parent)
    expected = dict(identity(os.getpid()), canary_inode=inode(canary))
    pending = ready.with_suffix(".tmp")
    pending.write_text(json.dumps(expected))
    pending.replace(ready)
    print("ready", flush=True)
    while True:
        time.sleep(1)


if __name__ == "__main__":
    mode, canary, ready = sys.argv[1:]
    canary, ready = Path(canary), Path(ready)
    assert canary.is_absolute() and ready.is_absolute()
    if mode == "serve":
        serve(canary, ready)
    else:
        assert mode == "check", mode
        print(json.dumps(check_peer(canary, ready)))
