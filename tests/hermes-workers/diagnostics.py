"""Read disposable VM cron state without creating or updating a ledger."""

from collections import deque
import json
from pathlib import Path
import sqlite3
import sys


def recent_lines(path: Path, count: int = 6) -> list[str]:
    with path.open(errors="replace") as stream:
        return list(deque(stream, maxlen=count))


def snapshot(home: Path) -> list[str]:
    records = []
    for relative in ("logs/gateway.log", "logs/agent.log", "logs/errors.log"):
        try:
            value = "".join(recent_lines(home / relative))
        except OSError as error:
            value = str(error)
        records.append(f"{relative}: {json.dumps(value)}")
    state = {}
    for relative in (
        "cron/jobs.json", "cron/ticker_heartbeat", "cron/ticker_last_success",
        "cron/ticker_last_error", "gateway_state.json", "test-job.json",
    ):
        try:
            state[relative] = (home / relative).read_text(errors="replace")
        except OSError as error:
            state[relative] = str(error)
    records.append("state: " + json.dumps(state))
    records.append("external-workers: " + json.dumps(sorted(
        path.name for path in (home / "cron/external-workers").glob("*")
    )))
    for path in sorted((home / "cron/output").glob("*/*")):
        try:
            value = "".join(recent_lines(path, count=12))
        except OSError as error:
            value = str(error)
        records.append(f"{path.relative_to(home)}: {json.dumps(value)}")
    try:
        with sqlite3.connect((home / "cron/executions.db").as_uri() + "?mode=ro", uri=True) as db:
            db.row_factory = sqlite3.Row
            rows = db.execute(
                "SELECT id, job_id, status, pid, process_started_at, handoff_pending, "
                "handoff_started_at, claimed_at, started_at, finished_at, error "
                "FROM executions ORDER BY claimed_at DESC LIMIT 3"
            ).fetchall()
            value = json.dumps([dict(row) for row in rows])
    except sqlite3.Error as error:
        value = str(error)
    records.append("executions: " + value)
    try:
        with (home / "logs/agent.log").open(errors="replace") as stream:
            value = "".join(deque(
                (line for line in stream if "systemd-run --user --scope probe" in line), maxlen=3,
            ))
    except OSError as error:
        value = str(error)
    records.append("scope-probe: " + json.dumps(value))
    return records


if __name__ == "__main__":
    print("\n".join(snapshot(Path(sys.argv[1]))))
