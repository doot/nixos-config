# Hermes worker confinement

PID 1 confines `user@<uid>.service` (M) before its user generators or services
run. M forks the static `hermes-gateway.service` (G); G's workers are attached
by M to sibling `hermes-worker-cron-*.scope` cgroups. M can inspect its descendants
across their additional Landlock domains, unlike independently confined peers.

The system `hermes-agent.service` is a confined lifecycle controller:
`systemctl --user --wait start hermes-gateway.service`. Its independently
confined `ExecStopPost` synchronously stops that exact user unit, including after
controller death or failed startup. Cleanup errors are not ignored. The
controller retains upstream restart policy; G has `Restart=no`, `ConditionUser`
and no activation target. Restarting/stopping the controller neither stops M
nor its sibling worker scopes. `Type=exec` acknowledges executable startup,
not gateway readiness or completed cron recovery.

G retains upstream argv, effective package (including optional dependencies),
process PATH/environment, working directory and umask, and receives its own
systemd `INVOCATION_ID`. The CLI runs in a manager-created service; its pipe/PTY
forwarder enters a runtime-directory-only Landlock domain before connecting.

M retains the system-owned mount, capability, syscall and namespace policy.
User services cannot undo that inherited policy, including with privileged exec
prefixes. There are no child mount directives: M already denies mount syscalls.
Landlock also enforces the write allowlist through other processes' `/proc`
aliases. M and ordinary manager-created services can write only M's private
cgroup delegation, never enclosing system cgroups; G and its workers enter an
additional Landlock domain denying **direct** cgroup writes. User-manager APIs
remain available intentionally. Missing Landlock support or a downgraded cgroup
namespace prevents startup.

The host-side network policy is unchanged. This does not protect against host
root, deny reads of credentials granted to Hermes, isolate mutually hostile
code within the manager domain, or impose an aggregate memory limit. Landlock
does not revoke previously opened descriptors: terminal and log streams are
intentionally inherited. No untrusted code should run before the launcher.
Cross-generation recovery also requires the package's manager-mediated worker
identity check; moving G under M alone does not let G2 inspect G1's workers.
The helper provides retention evidence, not signalling authority. Hermes's
process-management kill action refuses recovered Linux processes without their
original runtime handles; stopping them requires their original owner or an
operator.

## Tests

```sh
nix build .#checks.x86_64-linux.hermes-workers -L --override-input priv ./priv
```

The VM boots a minimal nspawn container without provider credentials. It tests:

- Static user-unit ownership, actual gateway PID/parent, distinct invocation,
  inherited mount namespace, environment/PATH, cwd and umask.
- CLI pipe/PTY operation; normal, relaxed and privileged-prefix user services;
  manager reexecution; live same-UID peer controls around each denial probe.
- Direct cgroup write-open denial in G and the real cron worker, bracketed by
  successful write-open controls under M. These probes do not migrate processes
  or change controller settings.
- Actual sibling worker scope membership across repeated gateway replacement
  and controller SIGKILL. A test-only exec shim removes the old heartbeat, then
  the new gateway must emit a heartbeat **after startup recovery** while the
  ledger still contains exactly one `running` row, before worker release.
  In G2, the recorded owner's direct identity must be inaccessible while the
  manager helper returns its matching fingerprint. A failed helper fails this
  proof even when conservative recovery retains the running row.
  Finally there must be one `completed` row and one completion side effect.
- Failed gateway exec propagating to the controller, successful stop-post
  cleanup, and explicit gateway stop without stopping M or other user services.

The exec shim observes and then execs the real package in the same PID; it does
not replace the scheduler or recovery implementation. Journal, ledger and scope
probe diagnostics remain available on worker/readiness timeouts.

Local checks (Python plus util-linux `setpriv` with Landlock):

```sh
python3 -B -m unittest discover -s tests/hermes-workers -p 'test_*.py' -v
python3 -B tests/hermes-workers/landlock.py
```

These exercise live peer controls, real Landlock denial on disposable files,
PTY ioctl rules, and the exec shim's PID/heartbeat provenance. They do not prove
systemd delegation, recovery or lifecycle behavior; that requires the CI VM.
