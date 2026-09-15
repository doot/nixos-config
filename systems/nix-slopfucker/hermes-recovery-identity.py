"""Linux read-only identity protocol. Also executed standalone with Python -I.

No Hermes imports: a manager probe must never recursively launch another probe.
"""
from dataclasses import asdict, dataclass
import json
import os
from pathlib import Path
import select
import subprocess
import sys
from typing import Literal


@dataclass(frozen=True)
class Identity:
    pid: int
    state: Literal["live", "absent", "inaccessible"]
    start_time: int | None = None
    version: int = 1


def valid_pid(pid):
    return type(pid) is int and 0 < pid < 2**31


def local_identity(pid: int) -> Identity:
    """Only ESRCH/pidfd exit proves absence; hidden procfs never does."""
    unknown = Identity(pid, "inaccessible")
    if not valid_pid(pid):
        return unknown
    try:
        fd = os.pidfd_open(pid, 0)
    except ProcessLookupError:
        return Identity(pid, "absent")
    except (OSError, AttributeError):
        return unknown
    try:
        poller = select.poll()
        poller.register(fd, select.POLLIN)
        if poller.poll(0):
            return Identity(pid, "absent")
        try:
            stat = Path(f"/proc/{pid}/stat").read_text(encoding="utf-8")
            # comm can contain whitespace and ')'; field 22 follows its last ')'.
            prefix, fields = stat.rsplit(")", 1)
            start = int(fields.split()[19])
            if int(prefix.split("(", 1)[0]) != pid or start <= 0:
                return unknown
        except (OSError, ValueError, IndexError, UnicodeError):
            return Identity(pid, "absent") if poller.poll(0) else unknown
        # Retaining the pidfd alone does not prevent numeric PID reuse. Reject
        # the snapshot if its original task exited at any point during the read.
        if poller.poll(0):
            return Identity(pid, "absent")
        return Identity(pid, "live", start)
    finally:
        os.close(fd)


def get_identity(pid: int) -> Identity:
    """Inspect locally, then once through the manager's ancestor domain."""
    result = local_identity(pid)
    if result.state != "inaccessible" or not valid_pid(pid):
        return result
    runtime = f"/run/user/{os.getuid()}"
    argv = [
        "@systemd_run@", "--user", "--wait", "--pipe", "--collect", "--quiet",
        "--property=Type=exec", "--property=RuntimeMaxSec=2s",
        "--property=TimeoutStopSec=1s", "--property=NoNewPrivileges=yes",
        "--", "@python@", "-I", "@identity_helper@", "--pid", str(pid),
    ]
    try:
        response = subprocess.run(
            argv, stdin=subprocess.DEVNULL, capture_output=True, text=True,
            timeout=4, check=False,
            env={"XDG_RUNTIME_DIR": runtime,
                 "DBUS_SESSION_BUS_ADDRESS": f"unix:path={runtime}/bus"},
        )
        if response.returncode != 0 or len(response.stdout) > 1024:
            return result
        data = json.loads(response.stdout)
        if (not isinstance(data, dict)
                or set(data) != {"version", "pid", "state", "start_time"}
                or type(data["version"]) is not int or data["version"] != 1
                or type(data["pid"]) is not int or data["pid"] != pid):
            return result
        if data["state"] == "live":
            if type(data["start_time"]) is not int or data["start_time"] <= 0:
                return result
        elif data["state"] not in ("absent", "inaccessible") or data["start_time"] is not None:
            return result
        return Identity(**data)
    except (OSError, subprocess.SubprocessError, ValueError, TypeError, UnicodeError):
        return result


def owner_state(pid: int, expected_start: int | None, *, local_only: bool = False) -> Literal["same", "gone", "unknown"]:
    """Classify a snapshot for retention; it is not a signalling handle."""
    identity = local_identity(pid) if local_only else get_identity(pid)
    if identity.state == "absent":
        return "gone"
    if (identity.state != "live" or type(expected_start) is not int
            or expected_start <= 0):
        return "unknown"
    return "same" if identity.start_time == expected_start else "gone"


def main():
    if len(sys.argv) != 3 or sys.argv[1] != "--pid" or not sys.argv[2].isascii() or not sys.argv[2].isdecimal():
        return 2
    pid = int(sys.argv[2])
    if not valid_pid(pid) or str(pid) != sys.argv[2]:
        return 2
    print(json.dumps(asdict(local_identity(pid)), separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
