"""Test-only exec shim: observe the gateway's own PID, domain and invocation."""

from contextlib import closing
from dataclasses import asdict
from importlib import import_module
import json
import os
from pathlib import Path
import sqlite3
import sys


def running_owner(home):
    """Read the execution owner, never the worker script's child PID."""
    database = home / "cron/executions.db"
    try:
        database.stat()
    except FileNotFoundError:
        # First startup precedes Hermes creating the ledger. Other errors fail.
        return None
    with closing(sqlite3.connect(database.as_uri() + "?mode=ro", uri=True)) as db:
        db.row_factory = sqlite3.Row
        rows = db.execute(
            "SELECT id, pid, process_started_at FROM executions WHERE status = 'running'"
        ).fetchall()
    assert len(rows) <= 1, f"ambiguous running execution owners: {len(rows)}"
    return dict(rows[0]) if rows else None


def recovery_identity_proof(home, identity=None):
    owner = running_owner(home)
    if owner is None:
        return {"owner": None}
    if identity is None:
        # A checkout's gateway.py must not shadow the installed gateway package.
        original_path = sys.path[:]
        try:
            sys.path[:] = [entry for entry in sys.path
                           if Path(entry).resolve() != Path(__file__).resolve().parent]
            identity = import_module("gateway.recovery_identity")
        finally:
            sys.path[:] = original_path
    pid = owner["pid"]
    # These calls run in the actual replacement gateway's inherited G2 domain,
    # before exec; only the production API may ask the ancestor manager for help.
    local = identity.local_identity(pid)
    mediated = identity.get_identity(pid)
    state = identity.owner_state(pid, owner["process_started_at"])
    return {
        "owner": owner,
        "local_identity": asdict(local),
        "manager_identity": asdict(mediated),
        "owner_state": state,
    }


def assert_recovery_identity(proof, owner):
    """Shared VM/unit assertion: conservative retention is not identity proof."""
    assert owner is not None and proof["owner"] == owner, (proof, owner)
    assert type(owner["pid"]) is int and owner["pid"] > 0, owner
    assert type(owner["process_started_at"]) is int and owner["process_started_at"] > 0, owner
    assert proof["local_identity"] == {
        "version": 1, "pid": owner["pid"], "state": "inaccessible", "start_time": None,
    }, ("local identity must be inaccessible in G2", proof)
    assert proof["manager_identity"] == {
        "version": 1, "pid": owner["pid"], "state": "live",
        "start_time": owner["process_started_at"],
    }, ("manager identity must match the exact ledger fingerprint", proof)
    assert proof["owner_state"] == "same", ("manager must establish same owner", proof)


def main():
    if sys.argv[2:] and sys.argv[2] == "gateway":
        home = Path(os.environ["HERMES_HOME"])
        # A fresh heartbeat then proves this invocation finished startup recovery.
        (home / "cron/ticker_heartbeat").unlink(missing_ok=True)
        invocation = os.environ["INVOCATION_ID"]
        destination = home / "gateway-starts" / invocation
        destination.mkdir(parents=True)
        identity_proof = recovery_identity_proof(home)
        if (home / "probe-gateway").exists():
            sys.path.insert(0, str(home / "scripts"))
            from probe import probe

            probe(Path("/srv/worker-canary"), destination, cgroup_writes=True)
        (destination / "started.json").write_text(json.dumps({
            "pid": os.getpid(),
            "invocation": invocation,
            "recovery_identity": identity_proof,
            "environment": {key: os.environ[key] for key in (
                "HOME", "HERMES_HOME", "HERMES_MANAGED", "PATH", "XDG_RUNTIME_DIR",
            )},
            "cwd": os.getcwd(),
            "status": Path("/proc/self/status").read_text(),
            "cgroup": Path("/proc/self/cgroup").read_text(),
        }))
    os.execv(sys.argv[1], sys.argv[1:])


if __name__ == "__main__":
    main()
