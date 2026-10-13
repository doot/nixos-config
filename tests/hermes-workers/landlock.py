"""Exercise Landlock against writable files and an unconfined same-UID peer."""

import fcntl
import json
import os
import pty
from pathlib import Path
import subprocess
import sys
import tempfile


RIGHTS = "write-file,remove-dir,remove-file,make-char,make-dir,make-reg,make-sock,make-fifo,make-block,make-sym,refer,truncate"


def payload(root: Path, peer: int, confined: bool) -> None:
    paths = [
        root / "outside" / "canary",
        Path(f"/proc/{peer}/root") / root.relative_to("/") / "outside/canary",
        Path(f"/proc/{peer}/cwd/canary"),
        Path(f"/proc/{peer}/fd/3"),
    ]
    for path in paths:
        try:
            with path.open("a") as target:
                target.write("write\n")
        except PermissionError:
            assert confined, f"unconfined control could not write {path}"
        else:
            assert not confined, f"Landlock allowed a write via {path}"
    (root / "state" / "allowed").write_text("allowed")
    print(json.dumps({"confined": confined, "paths_checked": len(paths)}))


def device_probe(denied: bool) -> None:
    fd = os.open("/dev/ptmx", os.O_RDWR | os.O_NOCTTY)
    try:
        try:
            fcntl.ioctl(fd, 0x80045430, bytes(4))  # TIOCGPTN is needed to allocate a PTY.
        except PermissionError:
            assert denied, "PTY ioctl was denied despite its allow rule"
        else:
            assert not denied, "device ioctl was allowed without an exception"
    finally:
        os.close(fd)
    if not denied:
        master, slave = pty.openpty()
        os.close(master)
        os.close(slave)
    print(json.dumps({"device_ioctl_denied": denied}))


def main() -> None:
    device_command = [sys.executable, __file__, "device"]
    subprocess.run(device_command + ["allowed"], check=True)
    restriction = ["setpriv", "--no-new-privs", "--landlock-access=fs:ioctl-dev"]
    subprocess.run(restriction + ["--"] + device_command + ["denied"], check=True)
    subprocess.run(
        restriction + ["--landlock-rule=path-beneath:ioctl-dev:/dev/pts", "--"]
        + device_command + ["allowed"], check=True,
    )
    with tempfile.TemporaryDirectory(prefix="hermes-landlock-") as directory:
        root = Path(directory)
        (root / "outside").mkdir()
        (root / "state").mkdir()
        (root / "outside/canary").touch()
        peer_code = (
            "import os,sys,time; "
            "fd=os.open('canary',os.O_RDWR); os.dup2(fd,3); "
            "print('ready',flush=True); time.sleep(60)"
        )
        with subprocess.Popen(
            [sys.executable, "-c", peer_code],
            cwd=root / "outside",
            stdout=subprocess.PIPE,
            text=True,
        ) as peer:
            try:
                assert peer.stdout is not None and peer.stdout.readline().strip() == "ready"
                command = [sys.executable, __file__, "payload", str(root), str(peer.pid)]
                subprocess.run(command + ["control"], check=True)
                subprocess.run(
                    [
                        "setpriv", "--no-new-privs", f"--landlock-access=fs:{RIGHTS}",
                        f"--landlock-rule=path-beneath:{RIGHTS}:{root / 'state'}",
                        "--",
                    ] + command + ["confined"],
                    check=True,
                )
            finally:
                peer.terminate()
                peer.wait(timeout=5)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "device":
        device_probe(sys.argv[2] == "denied")
    elif len(sys.argv) > 1:
        payload(Path(sys.argv[2]), int(sys.argv[3]), sys.argv[4] == "confined")
    else:
        main()
