"""Create a scheduled script-only job; execution belongs to the real gateway."""

from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path

from cron.jobs import create_job


job = create_job(
    prompt=None,
    name="restart-survival",
    schedule=(datetime.now(timezone.utc) + timedelta(seconds=2)).isoformat(),
    repeat=1,
    deliver="local",
    script="worker.py",
    no_agent=True,
)
(Path(os.environ["HERMES_HOME"]) / "test-job.json").write_text(json.dumps(job))
