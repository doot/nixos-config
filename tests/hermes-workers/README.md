# Hermes worker confinement

The native gateway and the container's `user@<uid>.service` share a system-owned
sandbox. Gateway-created scopes inherit the gateway's restrictions; services,
user generators, and reexecutions inherit the user manager's restrictions. The
interactive CLI also runs as a manager-created service. Its forwarding process
enters Landlock before connecting to the manager, with writes limited to the
runtime directory and selected devices.

Landlock enforces the write allowlist independently of mount namespaces,
including access through another process's `/proc` paths. State, runtime files,
private temporary directories and selected terminal devices remain writable.
Manager-launched processes can write the manager's private delegated cgroup
hierarchy, not the enclosing system cgroups. Missing
Landlock support or a downgraded cgroup namespace prevents startup.

The host-side network policy is unchanged. This does not protect against host
root, deny reads of credentials granted to Hermes, or impose an aggregate memory
limit. Landlock does not revoke previously opened descriptors: terminal and log
streams are intentionally inherited. No untrusted code should run before the
confinement launcher.

## Tests

```sh
nix build .#checks.x86_64-linux.hermes-workers -L --override-input priv ./priv
```

The VM boots a minimal nspawn container, checks ordinary and deliberately
less-restricted user services against writable canaries and an unconfined
same-UID peer, and runs a script-only job through the actual gateway scheduler.
The job must complete once across a gateway restart. Manager reexecution is
also tested. No provider credentials or model calls are needed.

The package build tests the installed probe with a mocked systemd launch; the
VM test exercises the real scope path. `landlock.py` is a standalone Linux
control/denial test requiring Python and util-linux `setpriv` with Landlock.
