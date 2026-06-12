# Hermes locked-down container — rollout & threat model

`hermes-container.nix` moves the Hermes agent off the host and into a
declarative NixOS container (systemd-nspawn) so that **every** execution path —
the long-running gateway *and* interactive `doot` TUI/CLI sessions — is forced
through one capability boundary the agent cannot reconfigure.

## Why this replaces the host-native module

The host-native `services.hermes-agent` only hardens the **gateway** systemd
unit. The interactive TUI runs in the operator's login session (`user.slice`),
entirely outside that unit — so an agent talking to you through the TUI had:

- a reachable **nix daemon** (`nix-shell`/`nix build` → install anything),
- a **writable `config.yaml`** it owned (could flip `approvals.mode: off`),
- **full LAN reach** (192.168.1.0/24 and every internal host),
- and **no egress filtering** at all.

The container collapses both entry points into one network + mount + pid
namespace, with all egress policy enforced **host-side** where the agent has no
reach.

## What it enforces (the two goals signed off on)

1. **No arbitrary package installs**
   - `nix.enable = false` inside the container → no nix daemon, so
     `nix build` / `nix-shell` / `nix run` cannot realise new derivations.
     *(This is the exact vector used to materialise Python on the host.)*
   - No Python / pip / uv / conda on the container PATH.
   - **Accepted residual:** `npm` is bundled in the hermes package wrapper and
     cannot be cleanly removed; NAT egress does **not** block `registry.npmjs.org`.
     Killing casual `npm i` too would need a container-local filtering resolver
     (dnsmasq `address=/registry.npmjs.org/0.0.0.0`) — deliberately left out per
     your call. See "Future tightening".

2. **LAN isolation**
   - `privateNetwork` veth; host NATs the container to the internet; the host
     firewall **DROPs** container→RFC1918. The agent reaches the internet + the
     Copilot API but **not** the LAN.

## Honest limitations

- **Config immutability is *eventual*, not hard.** `configFile` re-installs the
  store-rendered config on every host rebuild (and `system.autoUpgrade` pulls
  `main` regularly), so any self-edit is reverted on the next rebuild — but the
  on-disk file is still `hermes`-owned and writable *between* rebuilds. For
  **hard** immutability, add a read-only bind-mount shadowing the file inside
  the container (snippet in "Future tightening"). Not enabled by default because
  it breaks `hermes config set` / `/model` from the TUI.
- **Arbitrary code can still run** (bundled node, a fetched tarball, etc.). This
  raises the bar a lot; it is not a wall. You accepted this.
- **uid sharing.** `privateUsers = false` so bind-mounted state ownership is
  coherent (host `hermes` = 994:992 = container `hermes`). A compromise of the
  container is therefore a compromise of uid 994 on the host. Stronger:
  `privateUsers = true` + idmapped mounts (future upgrade).

## Rollout — test-first, never `switch` blind

This is gated **off** by default (`slop.hermesContainer.enable = false`) because
the hermes uv2nix closure (~5 GB, thousands of tiny files) OOMs the Proxmox
image builder's `cptofs` step — same reason the native service ships disabled.
Enable and roll it out **on the live VM**:

```sh
# 0. On the VM, ensure the secret exists (root-owned, out of repo):
sudo install -d -m 0700 -o root -g root /var/lib/hermes-secrets
sudo install -m 0600 /dev/null /var/lib/hermes-secrets/agent.env
sudoedit /var/lib/hermes-secrets/agent.env      # COPILOT_GITHUB_TOKEN=... (or run `hermes auth` post-start)

# 1. Enable the container in systems/nix-slopfucker/hermes-container.nix:
#       slop.hermesContainer.enable = true;
#    and disable the host-native service in hermes.nix (services.hermes-agent.enable = false).

# 2. Build WITHOUT activating — catches eval/build errors with zero risk:
sudo nixos-rebuild build --flake .#nix-slopfucker

# 3. Activate for THIS BOOT ONLY (a reboot reverts if anything is wrong):
sudo nixos-rebuild test --flake .#nix-slopfucker

# 4. Verify the boundary (see "Verification" below). If anything is off,
#    just reboot to roll back. Only once happy:
sudo nixos-rebuild switch --flake .#nix-slopfucker
```

## Verification (run after `test`)

```sh
# Container is up:
machinectl list | grep hermes

# Gateway running inside it:
machinectl shell --uid=hermes hermes@hermes /run/current-system/sw/bin/systemctl status hermes-agent

# LAN is blocked but internet works (run INSIDE the container):
machinectl shell --uid=hermes hermes@hermes /run/current-system/sw/bin/bash -c \
  'curl -m5 -so /dev/null -w "internet=%{http_code}\n" https://api.github.com; \
   curl -m5 -so /dev/null -w "LAN=%{http_code}\n" http://192.168.1.1 || echo "LAN=BLOCKED (good)"'

# nix daemon is gone (should fail):
machinectl shell --uid=hermes hermes@hermes /run/current-system/sw/bin/bash -c \
  'nix --version 2>&1 | head -1 || echo "nix absent (good)"'

# Host firewall has the LAN-deny rules at the top of FORWARD:
sudo iptables -L FORWARD -n --line-numbers | head

# Interactive TUI as doot goes THROUGH the container:
hermes            # the wrapper → machinectl shell into the container
```

## Future tightening (documented, not enabled)

- **Hard config immutability** — shadow the file read-only inside the container:
  ```nix
  containers.hermes.bindMounts."/var/lib/hermes/.hermes/config.yaml" = {
    hostPath = "${hermesConfigFile}";   # store path
    isReadOnly = true;
  };
  ```
  (Breaks TUI-side `hermes config set`; that's the trade.)
- **Block npm/pip registries** — container-local dnsmasq with
  `address=/registry.npmjs.org/0.0.0.0` (+ pypi.org, files.pythonhosted.org).
- **Stronger uid isolation** — `privateUsers = true` + idmapped bind mounts.
- **Egress allowlist** — if you later want true "only these domains", put a
  filtering CONNECT proxy in the host netns and force the container through it;
  the container can't bypass it because its only route out is the veth.
