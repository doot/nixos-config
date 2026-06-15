{
  lib,
  pkgs,
  inputs,
  ...
}: let
  # Private (RFC1918 / link-local / CGNAT) IPv4 ranges the agent must NOT reach.
  # Enforced host-side as FORWARD DROPs on the container's veth (LAN isolation).
  # IPv6 is intentionally not provisioned for the container, so no v6 list.
  lanDenyCidrs = [
    "10.0.0.0/8"
    "172.16.0.0/12"
    "192.168.0.0/16"
    "169.254.0.0/16" # link-local / cloud metadata
    "100.64.0.0/10" # CGNAT
  ];

  # Host↔container point-to-point veth (a /30 link, never forwarded → not LAN).
  hostAddress = "10.100.0.1";
  localAddress = "10.100.0.2";
  externalInterface = "ens18";
  vethHost = "ve-hermes";

  # Interactive TUI for doot: drops into the container as the hermes user with a
  # real PTY, so doot drives the SAME agent the gateway runs — one config, one
  # state dir, one boundary. There is no separate native CLI path to bypass.
  hermesTui = pkgs.writeShellScriptBin "hermes" ''
    set -euo pipefail
    if ! ${pkgs.systemd}/bin/machinectl show hermes >/dev/null 2>&1; then
      echo "hermes container not running. Start it with: sudo machinectl start hermes" >&2
      exit 1
    fi
    exec ${pkgs.systemd}/bin/machinectl shell --uid=hermes hermes@hermes \
      /run/current-system/sw/bin/hermes "$@"
  '';
in {
  # Neovim role pulls in npm, which we do not want anywhere on this host.
  roles.neovim.enable = lib.mkForce false;

  # Host-side hermes user/group: owns the bind-mounted state on disk and lets
  # doot share the workspace via the group. NO hardcoded uid/gid — NixOS keeps
  # the existing allocation stable through its uid-map (hermes already exists),
  # and the container bridges ownership by-owner (owneridmap), never by number.
  users = {
    groups.hermes = {};
    users.hermes = {
      isSystemUser = true;
      group = "hermes";
      home = "/var/lib/hermes";
    };
    users.doot.extraGroups = ["hermes"];
  };

  # ── The agent runs ONLY inside this declarative container ─────────────────
  # The ~5 GB hermes uv2nix closure is excluded from the Proxmox IMAGE build in
  # proxmox.nix (boot.enableContainers = false there), which keeps the 1 GB
  # cptofs builder from OOMing. The live VM builds it fine (4 G RAM); the agent
  # arrives on first post-boot autoUpgrade. `nix flake check` only evaluates.
  containers.hermes = {
    autoStart = true;

    # One shared namespace for gateway + TUI. Egress policy is enforced
    # host-side (below), where the agent cannot reach or rewrite it.
    privateNetwork = true;
    inherit hostAddress localAddress;

    # Private user namespace: container uids are offset into a high host range,
    # so a container escape lands on a powerless, unmapped host uid — NOT the
    # host hermes uid, and container-root is NOT host root.
    privateUsers = "pick";

    # Thread the flake inputs into the container's nested evaluation so it can
    # import the hermes-agent module (containers don't inherit host specialArgs).
    specialArgs = {inherit inputs;};

    # State + secret are bound via extraFlags (not `bindMounts`) so we can pick
    # the id-mapping mode that keeps ownership coherent under privateUsers="pick"
    # WITHOUT hardcoding any uid:
    #   • state  → owneridmap: in-container owner (hermes) ↔ host inode owner
    #              (host hermes), purely by ownership — no numbers anywhere.
    #   • secret → rootidmap: container-root (runs activation + reads the env
    #              file) ↔ host root (the file's owner). Read-only.
    # RUNTIME-VERIFY on first boot (cannot be checked at eval time): the agent
    # must see its own state, not `nobody`:
    #   machinectl shell --uid=hermes hermes@hermes \
    #     /run/current-system/sw/bin/stat -c '%U:%G' /var/lib/hermes
    #   → hermes:hermes   (if nobody:nogroup, the idmap mode needs adjusting)
    extraFlags = [
      "--bind=/var/lib/hermes:/var/lib/hermes:owneridmap"
      "--bind-ro=/var/lib/hermes-secrets/agent.env:/var/lib/hermes-secrets/agent.env:rootidmap"
    ];

    config = {
      lib,
      inputs,
      ...
    }: {
      imports = [inputs.hermes-agent.nixosModules.default];

      # No nix daemon → no `nix build`/`nix-shell`/`nix run` self-install.
      # No python/pip/uv on PATH either. This is the package-install lockdown.
      nix.enable = false;

      networking = {
        # DNS goes THROUGH the host resolver (systemd-resolved listening on the
        # veth host address, configured below), so the container is subject to
        # whatever DNS filtering/blocking the host network enforces. It does NOT
        # talk to public resolvers directly — that would bypass network policy.
        useHostResolvConf = false;
        nameservers = [hostAddress];
        # Leaf system: it does not manage the host firewall.
        firewall.enable = lib.mkForce false;
      };

      # ── THE Hermes config — single source of truth, defined once, here ────
      services.hermes-agent = {
        enable = true;
        # CLI on the container PATH + HERMES_HOME exported, so the machinectl
        # TUI wrapper and the gateway share one state dir.
        addToSystemPackages = true;

        settings = {
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

        # API key lives ONLY in this out-of-repo file (root:root 0600, never
        # committed), bind-mounted in read-only via rootidmap above:
        #   sudo install -d -m 0700 -o root -g root /var/lib/hermes-secrets
        #   sudo install -m 0600 /dev/null /var/lib/hermes-secrets/agent.env
        #   sudoedit /var/lib/hermes-secrets/agent.env   # COPILOT_GITHUB_TOKEN=...
        environmentFiles = ["/var/lib/hermes-secrets/agent.env"];

        # No compilers or package managers visible to the agent.
        extraPackages = [];
      };

      # Defense-in-depth hardening on the gateway unit (cap-drop + kernel/proc
      # protections). Egress filtering lives host-side as NAT + firewall DROP.
      systemd.services.hermes-agent.serviceConfig = {
        # Drop all capabilities — agent runs unprivileged and NoNewPrivileges is already set.
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";

        # Kernel / host protections.
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectProc = "invisible";

        LockPersonality = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
      };

      system.stateVersion = "26.05";
    };
  };

  # Make the host's systemd-resolved stub also listen on the veth host address,
  # so the container can resolve THROUGH it (and inherit host/network DNS
  # policy) instead of reaching public resolvers. The host normally only listens
  # on 127.0.0.53; this adds the container-facing address.
  services.resolved.settings.Resolve.DNSStubListenerExtra = [hostAddress];

  # ── Host-side egress policy (the agent cannot reach or change this) ───────
  networking = {
    # NAT the container link out the uplink (enables ip_forward + masquerade).
    nat = {
      enable = true;
      inherit externalInterface;
      internalInterfaces = [vethHost];
    };

    firewall = {
      # Allow the container to reach the resolved stub on the veth (DNS only).
      interfaces.${vethHost} = {
        allowedUDPPorts = [53];
        allowedTCPPorts = [53];
      };

      # LAN isolation: DROP container→RFC1918 forwarded traffic, inserted at the
      # TOP of FORWARD (before nat's accept). We use extraCommands (raw iptables)
      # deliberately: the native typed alternative
      # (networking.firewall.extraForwardRules + filterForward) REQUIRES the
      # nftables firewall backend, and this host runs the iptables-nft backend
      # that fail2ban + the NAT rules above already depend on. Switching backends
      # for this one rule risks the SSH path, so we add to the existing chain.
      # Verify after rebuild: `iptables -L FORWARD -n --line-numbers`.
      extraCommands =
        lib.concatMapStringsSep "\n" (cidr: ''
          iptables -I FORWARD 1 -i ${vethHost} -d ${cidr} -j DROP
        '')
        lanDenyCidrs;

      extraStopCommands =
        lib.concatMapStringsSep "\n" (cidr: ''
          iptables -D FORWARD -i ${vethHost} -d ${cidr} -j DROP 2>/dev/null || true
        '')
        lanDenyCidrs;
    };
  };

  # Interactive TUI for regular users + seamless `machinectl shell` for wheel members.
  # The polkit rule is scoped to the `hermes` machine specifically (via
  # action.lookup("machine")) so it does not grant passwordless shell into any
  # other machine that might be registered with systemd-machined later.
  environment.systemPackages = [hermesTui];
  security.polkit.extraConfig = ''
    polkit.addRule(function(action, subject) {
      if (action.id == "org.freedesktop.machine1.shell" &&
          action.lookup("machine") == "hermes" &&
          subject.isInGroup("wheel")) {
        return polkit.Result.YES;
      }
    });
  '';
}
