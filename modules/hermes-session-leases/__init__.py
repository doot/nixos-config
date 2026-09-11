"""Record which Hermes sessions currently have a live TUI attached.

Session transcripts survive a host reboot; the knowledge of *which* sessions were
open in terminal tabs does not. This writes that set to disk so it can be replayed.

Liveness is the attached process, not the file: a lease whose PID is gone but whose
file remains is a session that died with the host — exactly the restore set.
"""

from __future__ import annotations

import json
import os
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Optional

LEASE_DIR = Path(os.environ.get("HERMES_LEASE_DIR", Path.home() / ".hermes" / "live"))


@dataclass(frozen=True)
class Lease:
    """A session with a terminal attached. `pid` is the liveness oracle."""

    session_id: str
    pid: int
    tty: str
    cwd: str
    platform: str
    model: str
    updated_at: float


def _proc_stat_fields(pid: int) -> Optional[list[str]]:
    try:
        raw = Path(f"/proc/{pid}/stat").read_text()
    except OSError:
        return None
    # comm may contain spaces/parens; everything after the final ')' is positional.
    close = raw.rfind(")")
    if close == -1:
        return None
    return raw[close + 2 :].split()


def _tty_of(pid: int) -> Optional[str]:
    fields = _proc_stat_fields(pid)
    if not fields or len(fields) < 5:
        return None
    tty_nr = int(fields[4])  # field 7 (tty_nr), 0 when not attached to a terminal
    if tty_nr == 0:
        return None
    return f"{os.major(tty_nr)}:{os.minor(tty_nr)}"


def _ppid_of(pid: int) -> Optional[int]:
    fields = _proc_stat_fields(pid)
    if not fields or len(fields) < 2:
        return None
    return int(fields[1])  # field 4 (ppid)


def _terminal_owner() -> tuple[int, str]:
    """Walk to the outermost ancestor sharing our controlling terminal.

    The hook runs deep inside the process tree (python <- node <- hermes); the
    lease must name the process whose death means the tab is gone, which is the
    top of that chain, not the leaf that happens to execute this code.
    """
    pid = os.getpid()
    tty = _tty_of(pid)
    if tty is None:
        return pid, ""
    owner = pid
    cursor = pid
    for _ in range(32):  # bounded: never trust a parent chain to terminate
        parent = _ppid_of(cursor)
        if not parent or parent <= 1:
            break
        if _tty_of(parent) != tty:
            break
        owner = parent
        cursor = parent
    return owner, tty


def _write_lease(session_id: str, platform: str, model: str) -> None:
    if not session_id:
        return
    pid, tty = _terminal_owner()
    if not tty:
        return  # headless (gateway, cron, subagent): no tab to restore

    lease = Lease(
        session_id=session_id,
        pid=pid,
        tty=tty,
        cwd=os.getcwd(),
        platform=platform or "cli",
        model=model or "",
        updated_at=time.time(),
    )

    LEASE_DIR.mkdir(parents=True, exist_ok=True)
    path = LEASE_DIR / f"{pid}.json"
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(asdict(lease), indent=2))
    tmp.replace(path)  # atomic: a reader never sees a half-written lease


def _on_session_start(session_id: str = "", model: str = "", platform: str = "", **_kw) -> None:
    _write_lease(session_id, platform, model)


def _pre_llm_call(session_id: str = "", model: str = "", platform: str = "", **_kw) -> None:
    # Per-turn heartbeat. on_session_start does not fire on resume, so this is
    # what keeps a restored session in the working set.
    _write_lease(session_id, platform, model)


def register(ctx) -> None:
    ctx.register_hook("on_session_start", _on_session_start)
    ctx.register_hook("pre_llm_call", _pre_llm_call)
