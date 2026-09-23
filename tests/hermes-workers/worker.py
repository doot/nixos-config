"""Cron payload whose lifetime deliberately crosses a gateway restart."""

import os
from pathlib import Path
import time

from probe import probe


home = Path(os.environ["HERMES_HOME"])
probe(Path("/srv/worker-canary"), home, cgroup_writes=True)
(home / "worker-ready").write_text(str(os.getpid()))
deadline = time.monotonic() + 360
while not (home / "release-worker").exists():
    if time.monotonic() >= deadline:
        raise TimeoutError("test did not release the cron worker")
    time.sleep(0.1)

probe(Path("/srv/worker-canary"), home, cgroup_writes=True)
with (home / "completions").open("a") as target:
    target.write("completed\n")
print("cron worker survived gateway restart")
