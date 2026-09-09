"""Cron payload whose lifetime deliberately crosses a gateway restart."""

import os
from pathlib import Path
import time

from probe import probe


home = Path(os.environ["HERMES_HOME"])
probe(Path("/srv/worker-canary"), home)
(home / "worker-ready").write_text(str(os.getpid()))
deadline = time.monotonic() + 120
while not (home / "release-worker").exists():
    if time.monotonic() >= deadline:
        raise TimeoutError("test did not release the cron worker")
    time.sleep(0.1)

with (home / "completions").open("a") as target:
    target.write("completed\n")
probe(Path("/srv/worker-canary"), home)
print("cron worker survived gateway restart")
