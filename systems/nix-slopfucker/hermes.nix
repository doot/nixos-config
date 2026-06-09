{
  config,
  lib,
  ...
}: let
  # Hosts the agent is allowed to reach directly (L3/IP, all ports on that host).
  # Empty = internet-only. To allow a specific internal host, add its /32 CIDR, e.g.:
  #   (import ../../common/network.nix).ips.nix-media-docker + "/32"
  # Caveat: per-host, not per-service — allowing a host exposes ALL its open ports.
  # Subdomain-level restriction (same-IP nginx vhosts) needs a future SNI-filtering
  # egress proxy or mesh network.
  allowedInternalHosts = [];
in {
  roles = {
    neovim.enable = lib.mkForce false;
    alloy.enable = lib.mkForce false;
    nixos-changelog.enable = lib.mkForce false;
  };
  services.hermes-agent = {
    # Off for the image build: the uv2nix Python closure (~5 GB across thousands
    # of small venv files) OOMs the Proxmox image builder's `cptofs` step — a
    # fixed-1GB-RAM QEMU VM with no exposed `memSize` option (nsf's closure is
    # large too, but lacks this file-count profile and builds fine at the default).
    #
    # Deploy sequence: build + restore this minimal image, boot it, set up
    # /var/lib/hermes-secrets/agent.env (below), then flip this to `true` and run
    # `nixos-rebuild switch --flake github:doot/nixos-config#nix-slopfucker` ON the VM
    # — ordinary system activation, using its own 4G RAM / 50G disk, no
    # image-builder constraint.
    enable = false;
    addToSystemPackages = true;

    # Provider/model — set one of:
    #   Anthropic:       "anthropic/claude-sonnet-4"      env file: ANTHROPIC_API_KEY=...
    #   GitHub Copilot:  "github_copilot/claude-sonnet-4" OAuth: run `hermes auth` post-deploy
    settings.model.default = "github_copilot/claude-sonnet-4"; # TODO: confirm provider/model

    # API keys live ONLY in this out-of-repo file (root:root 0600, never committed):
    #   sudo install -d -m 0700 -o root -g root /var/lib/hermes-secrets
    #   sudo install -m 0600 /dev/null /var/lib/hermes-secrets/agent.env
    #   sudoedit /var/lib/hermes-secrets/agent.env   # ANTHROPIC_API_KEY=sk-ant-...
    #   sudo nixos-rebuild switch
    environmentFiles = ["/var/lib/hermes-secrets/agent.env"];

    # No extra packages — the module's path already includes bash/coreutils/git wrapped with
    # the hermes binary. No compilers or package managers are visible to the agent.
    extraPackages = [];
  };

  # Extra containment layered on top of the module baseline
  # (ProtectSystem=strict, NoNewPrivileges, PrivateTmp, ReadWritePaths, User/Group=hermes).
  # Conservative set: skips SystemCallFilter, RestrictNamespaces, RestrictAddressFamilies,
  # and MemoryDenyWriteExecute (last one breaks Node's V8 JIT).
  #
  # Gated on `enable`: setting `serviceConfig` unconditionally would define a stub
  # `hermes-agent.service` unit (no ExecStart) even while the module is off for the
  # image build — orphaned and pointless.
  systemd.services.hermes-agent.serviceConfig = lib.mkIf config.services.hermes-agent.enable {
    # Drop all capabilities — agent runs unprivileged and NoNewPrivileges is already set.
    CapabilityBoundingSet = "";
    AmbientCapabilities = "";

    # Kernel / host protections.
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectKernelLogs = true;
    ProtectControlGroups = true;
    ProtectClock = true;
    ProtectHostname = true;
    ProtectProc = "invisible";
    # Module sets ProtectHome=false (HOME=/var/lib/hermes). Override: /home and /root are
    # irrelevant to the agent and should not be visible.
    ProtectHome = lib.mkForce true;
    PrivateDevices = true;
    LockPersonality = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;

    # Per-service egress filter (cgroup-scoped BPF, applied before nftables).
    # "any" (prefix 0) keeps internet + LLM API open; RFC1918/link-local/ULA denies win for
    # the LAN (longer prefix); allowedInternalHosts /32 entries punch specific hosts back through.
    IPAddressAllow = ["any"] ++ allowedInternalHosts;
    IPAddressDeny = [
      "10.0.0.0/8"
      "172.16.0.0/12"
      "192.168.0.0/16"
      "169.254.0.0/16" # link-local / cloud metadata
      "100.64.0.0/10" # CGNAT
      "fc00::/7" # IPv6 ULA
      "fe80::/10" # IPv6 link-local
    ];
  };
}
