# hermes-container.nix — run the Hermes agent inside a declarative NixOS
# container (systemd-nspawn) so that ALL execution paths — the long-running
# gateway service AND interactive TUI/CLI sessions launched by `doot` — are
# forced through one capability boundary the agent cannot reconfigure.
#
# WHY A CONTAINER (vs. the host-native module + per-service hardening):
#   The native module only hardens the *gateway* systemd unit. The interactive
#   TUI runs in the operator's login session (user.slice), completely outside
#   that unit — so none of the egress/cap/namespace hardening applied to it.
#   A NixOS container gives us a single network + mount + pid namespace that
#   both entry points share, with all egress policy enforced HOST-SIDE where
#   the agent has no reach.
#
# WHAT THIS BUYS (the two goals the operator signed off on):
#   1. No arbitrary package installs:
#        - `nix.enable = false` inside the container → no nix-daemon, so
#          `nix build`/`nix-shell`/`nix run` cannot realise new derivations.
#          (This was the vector used to materialise Python on the host.)
#        - No Python/pip/uv/conda on PATH inside the container.
#        - npm is bundled in the hermes package wrapper and cannot be removed,
#          but the LAN-deny + NAT-only egress below does NOT block npmjs.org;
#          this is the residual the operator explicitly accepted. (To also kill
#          casual `npm i`, add a container-local filtering resolver later.)
#   2. LAN isolation:
#        - privateNetwork veth, host does NAT to the internet, host firewall
#          DROPs container→RFC1918, so the agent reaches the internet + LLM API
#          but NOT 192.168.1.0/24 or any other internal host.
#
# IMAGE-BUILD SAFETY:
#   The hermes uv2nix closure (~5 GB, thousands of tiny venv files) OOMs the
#   Proxmox image builder's `cptofs` step. Pulling that closure into a CONTAINER
#   would do the same — so the whole container is gated OFF by default and
#   enabled on the live VM after deploy (see README-hermes-container.md). This
#   mirrors the existing `services.hermes-agent.enable = false` image dance.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: let
  cfg = config.slop.hermesContainer;

  # ── Tunables (review these) ────────────────────────────────────────────
  # Point-to-point veth link between host and container. Deliberately a /30 in
  # 10.100.0.0 — this is the host↔container link only; it is NOT the LAN and is
  # never forwarded (host-to-container is INPUT, not FORWARD), so the 10.0.0.0/8
  # LAN-deny below does not affect it.
  hostAddress = "10.100.0.1";
  localAddress = "10.100.0.2";

  # Host uplink toward the real network / internet.
  externalInterface = "ens18";

  # systemd-nspawn names the host side of the veth ve-<name>.
  vethHost = "ve-hermes";

  # Pin the in-container hermes identity to the host's so bind-mounted state
  # (owned 994:992 on the host) has coherent ownership across the namespace.
  # privateUsers is left false (uids shared host↔container) for the same reason.
  hermesUid = 994;
  hermesGid = 992;

  # Private (RFC1918 / link-local / CGNAT) ranges the container must NOT reach.
  # Same list the native module used, minus the veth link which is never
  # forwarded. IPv6 is intentionally not provisioned for the container.
  lanDenyCidrs = [
    "10.0.0.0/8"
    "172.16.0.0/12"
    "192.168.0.0/16"
    "169.254.0.0/16" # link-local / cloud metadata
    "100.64.0.0/10" # CGNAT
  ];

  # Declarative config rendered to the Nix store. Passed to the module as
  # `configFile`, so the activation script re-installs it on every rebuild —
  # any edit the agent makes to its own config.yaml is reverted on the next
  # host rebuild (autoUpgrade pulls main regularly → eventual immutability).
  # For HARD immutability, see the read-only bind-mount note in the README.
  hermesSettings = {
    model = {
      provider = "copilot";
      default = "claude-opus-4.8";
    };
    memory = {
      memory_enabled = true;
      user_profile_enabled = true;
    };
    display = {
      skin = "slate";
      compact = true;
      show_cost = true;
      timestamps = true;
      interface = "tui";
    };
    privacy.redact_pii = true;
    dashboard.theme = "ember";
    agent = {
      environment_hint = "You are running inside a locked-down NixOS container (no nix daemon, no LAN egress).";
      personality = "noir";
    };
    terminal.cwd = "/var/lib/hermes/workspace";
  };

  hermesConfigFile =
    pkgs.writeText "hermes-config.yaml" (builtins.toJSON hermesSettings);

  # Wrapper that drops `doot` into an interactive TUI INSIDE the container, as
  # the hermes user, with a real PTY. machinectl shell allocates a proper pty
  # (raw `nixos-container run` has the prompt_toolkit \r vs \n problem noted in
  # the hermes-agent skill). Polkit rule below lets wheel use it without a
  # password prompt for this specific machine.
  hermesTuiWrapper = pkgs.writeShellScriptBin "hermes" ''
    set -euo pipefail
    if ! ${pkgs.systemd}/bin/machinectl show hermes >/dev/null 2>&1; then
      echo "hermes container is not running. Start it with: sudo machinectl start hermes" >&2
      exit 1
    fi
    # --uid runs the command as the container's hermes user; the binary path is
    # resolved INSIDE the container (its own /run/current-system).
    exec ${pkgs.systemd}/bin/machinectl shell --uid=hermes hermes@hermes \
      /run/current-system/sw/bin/hermes "$@"
  '';
in {
  options.slop.hermesContainer = {
    enable = lib.mkEnableOption ''
      the locked-down Hermes NixOS container.

      Gated OFF by default: the hermes closure OOMs the Proxmox image builder,
      so this is enabled on the live VM post-deploy, not baked into the image.
      See README-hermes-container.md for the test-first rollout runbook.
    '';
  };

  config = lib.mkIf cfg.enable {
    # ── Host identity for bind-mount coherence ────────────────────────────
    # The service runs INSIDE the container, but we keep a host-side hermes
    # user/group at the same numeric ids so the bind-mounted state directory
    # has coherent ownership and `doot` can share the workspace via the group.
    users = {
      groups.hermes.gid = hermesGid;
      users.hermes = {
        uid = hermesUid;
        group = "hermes";
        isSystemUser = true;
        home = "/var/lib/hermes";
      };
      users.doot.extraGroups = ["hermes"];
    };

    # ── The boundary: a declarative systemd-nspawn container ──────────────
    containers.hermes = {
      autoStart = true;

      # One shared namespace for gateway + TUI. Egress policy lives host-side.
      privateNetwork = true;
      inherit hostAddress localAddress;

      # uids shared with host (no userns) so bind-mounted state ownership is
      # coherent. Stronger isolation ("pick" + idmapped mounts) is a documented
      # future upgrade; out of scope for the two accepted goals.
      # NB: nixpkgs 26.11 changed this from bool to an enum ("no"/"identity"/
      # "pick" or a uid base) — "no" == the old `false` (shared uids).
      privateUsers = "no";

      # Pass the flake inputs into the container's nested NixOS evaluation so
      # it can import the hermes-agent module. (nixos-containers do NOT inherit
      # the host's specialArgs automatically.)
      specialArgs = {inherit inputs;};

      bindMounts = {
        # Live agent state + workspace, shared with the host so `doot` can
        # collaborate on the workspace and the existing sessions/skills/auth
        # carry over. Read-write.
        "/var/lib/hermes" = {
          hostPath = "/var/lib/hermes";
          isReadOnly = false;
        };
        # Secrets (API token) — read-only. Out-of-repo, root-owned on the host.
        "/var/lib/hermes-secrets/agent.env" = {
          hostPath = "/var/lib/hermes-secrets/agent.env";
          isReadOnly = true;
        };
      };

      config = {
        lib,
        inputs,
        ...
      }: {
        imports = [inputs.hermes-agent.nixosModules.default];

        # Pin the in-container identity to the host's numeric ids, lock down the
        # inside, and point DNS at public resolvers (no route to the LAN
        # resolver at 192.168.1.1 by design).
        users.groups.hermes.gid = hermesGid;
        users.users.hermes.uid = hermesUid;

        # No nix daemon → no `nix build`/`nix-shell`/`nix run` self-install.
        nix.enable = false;

        networking = {
          useHostResolvConf = false;
          nameservers = ["1.1.1.1" "9.9.9.9"];
          # The container is a leaf system; it does not manage the host firewall.
          firewall.enable = lib.mkForce false;
        };

        services.hermes-agent = {
          enable = true;
          # CLI on the container PATH + HERMES_HOME exported, so the machinectl
          # shell wrapper and the gateway share one state dir.
          addToSystemPackages = true;

          # Declarative, store-rendered config (re-installed every rebuild).
          configFile = hermesConfigFile;

          environmentFiles = ["/var/lib/hermes-secrets/agent.env"];

          # No extra packages, compilers, or package managers for the agent.
          extraPackages = [];
        };

        system.stateVersion = "26.05";
      };
    };

    # ── Host-side egress policy (the part the agent cannot touch) ─────────
    networking = {
      # NAT the container link out the uplink: enables ip_forward, masquerades
      # 10.100.0.0/30 → ens18, and adds the internal→external FORWARD accept.
      nat = {
        enable = true;
        inherit externalInterface;
        internalInterfaces = [vethHost];
      };

      # LAN isolation: DROP container→RFC1918 forwarded traffic. Inserted at the
      # TOP of FORWARD so it is evaluated before nat's accept. Backed by the
      # existing iptables-nft firewall (no backend switch → no SSH-lockout risk).
      # Verify after rebuild: `iptables -L FORWARD -n --line-numbers`.
      firewall.extraCommands =
        lib.concatMapStringsSep "\n" (cidr: ''
          iptables -I FORWARD 1 -i ${vethHost} -d ${cidr} -j DROP
        '')
        lanDenyCidrs;

      firewall.extraStopCommands =
        lib.concatMapStringsSep "\n" (cidr: ''
          iptables -D FORWARD -i ${vethHost} -d ${cidr} -j DROP 2>/dev/null || true
        '')
        lanDenyCidrs;
    };

    # ── Interactive TUI for doot, forced through the container ────────────
    environment.systemPackages = [hermesTuiWrapper];

    # Let wheel members open a shell in the hermes machine without a password
    # prompt (so the `hermes` wrapper is seamless for doot).
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id == "org.freedesktop.machine1.shell" &&
            subject.isInGroup("wheel")) {
          return polkit.Result.YES;
        }
      });
    '';
  };
}
