{
  lib,
  pkgs,
  inputs,
  config,
  ...
}: let
  # Single source of truth for the hermes uid/gid. The host hermes user is
  # pinned to these, and the container's hermes user mirrors the SAME bindings
  # (threaded in via specialArgs), so both independent NixOS systems agree on
  # the numeric owner of the shared state. See the host users block below for
  # why pinning is necessary (privateUsers = "no" + activation-time uid
  # allocation makes the value unreadable across the boundary otherwise).
  # Value adopted from this host's existing allocation; the number is incidental.
  hermesUid = 994;
  hermesGid = 992;

  # nmd's fqdn — fronts the agent's observability endpoints (Grafana/Prom/Loki).
  nmdFqdn = (import ../../common/network.nix).hosts.nix-media-docker.fqdn;

  # ── The agent's git identity ───────────────────────────────────────────────
  # Path INSIDE the container where the private SSH key is mounted
  agentKeyPath = "/var/lib/hermes-secrets/id_hermes";

  # Email used to sign git commits
  agentEmail = "slop@jhauschildt.com";

  # Public half of the sops-encrypted SSH signing key, for local verification only.
  # Kept here because the private half is unreadable at eval time.
  agentSigningKeyPub = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIC0ybf62lh60glDS8hMnqtkknBZFUPFVqOWZrfgATZWZ";

  # Allow verifying specific SSH signatures locally
  allowedSigners = pkgs.writeText "hermes-allowed-signers" ''
    ${agentEmail} namespaces="git" ${agentSigningKeyPub}
    jhauschildt@linkedin.com namespaces="git" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID2faMGyx7bfdnVYtXrqEJicP/q0HV441nPR9hIz8cJ7 jeremy@jhauschildt.com
  '';

  forgejoSshHost = (import ../../common/network.nix).hosts.nix-shitfucker.fqdn;

  # Internal hosts the agent may reach despite the LAN-wide deny below: each
  # becomes a whole-host ACCEPT in hermes-egress, ahead of the RFC1918 drops.
  # DEFAULT EMPTY — the agent is hostile; add hosts deliberately. (DNS needs no
  # entry; it goes to the host resolver on the veth.) For a single port, prefer
  # allowedInternalServices below.
  # nmd is whole-host: the agent uses several of its services (Forgejo, ntfy, …).
  allowedInternalHosts = [(import ../../common/network.nix).ips.nix-media-docker];

  # Port-scoped ACCEPTs: {host, ports} grants only those TCP ports on that host.
  # nsf hosts the private Forgejo repo the agent pushes to — SSH only.
  allowedInternalServices = [
    {
      host = (import ../../common/network.nix).ips.nix-shitfucker;
      ports = [22];
    }
  ];

  # Private (RFC1918 / link-local / CGNAT) IPv4 ranges the agent must NOT reach,
  # EXCEPT the allowlisted hosts above. Enforced host-side in the hermes-egress
  # chain on the container's veth. IPv6 is not provisioned for the container.
  lanDenyCidrs = [
    "10.0.0.0/8"
    "172.16.0.0/12"
    "192.168.0.0/16"
    "169.254.0.0/16" # link-local / cloud metadata
    "100.64.0.0/10" # CGNAT
  ];

  # Body of the `hermes-egress` iptables chain: allow the explicit hosts and
  # port-scoped services first, then deny the private ranges. Evaluated
  # top-to-bottom, so allow wins over deny; anything not matched falls through
  # to the internet.
  egressRules = lib.concatStringsSep "\n" (
    (map (host: "iptables -A hermes-egress -d ${host} -j ACCEPT") allowedInternalHosts)
    ++ (lib.concatMap (
        svc:
          map (
            port: "iptables -A hermes-egress -d ${svc.host} -p tcp --dport ${toString port} -j ACCEPT"
          )
          svc.ports
      )
      allowedInternalServices)
    ++ (map (cidr: "iptables -A hermes-egress -d ${cidr} -j DROP") lanDenyCidrs)
  );

  # Host↔container point-to-point veth (a /30 link, never forwarded → not LAN).
  # Both addresses are consumed by containers.hermes below (nixos-containers
  # configures the veth pair and the container's default route from them).
  hostAddress = "10.100.0.1";
  localAddress = "10.100.0.2";
  externalInterface = "ens18";
  vethHost = "ve-hermes";

  # Forwarded into the container so the TUI can identify the terminal and enable
  # modified-key reporting (Shift+Enter). Every hop must cooperate: the client
  # sends them via SendEnv, sshd accepts them (services.openssh in
  # common/default.nix), and machinectl forwards only TERM without this list.
  terminalIdentityEnv = [
    "TERM"
    "TERM_PROGRAM"
    "TERM_PROGRAM_VERSION"
    "COLORTERM"
    "WEZTERM_REMOTE_PANE"
  ];

  # Interactive TUI for regular users: drops into the container as the hermes
  # user with a real PTY, so they drive the SAME agent the gateway runs — one
  # config, one state dir, one boundary. No separate native CLI path to bypass.
  # `hermes@hermes` = user `hermes` @ machine `hermes`. (machinectl shell does
  # not propagate the child's exit code — fine for an interactive TUI.)
  hermesTui = pkgs.writeShellScriptBin "hermes" ''
    set -euo pipefail
    if [ "$(${pkgs.systemd}/bin/machinectl show hermes -p State --value 2>/dev/null)" != "running" ]; then
      echo "hermes container is not running. Start it with: sudo machinectl start hermes" >&2
      exit 1
    fi

    # Resolve values here rather than passing bare `--setenv=NAME`, which
    # inherits from this environment and would forward unset vars as empty.
    setenv=()
    for var in ${lib.concatStringsSep " " terminalIdentityEnv}; do
      if [ -n "''${!var-}" ]; then
        setenv+=("--setenv=$var=''${!var}")
      fi
    done

    exec ${pkgs.systemd}/bin/machinectl shell "''${setenv[@]}" hermes@hermes \
      /run/current-system/sw/bin/hermes "$@"
  '';
in {
  # Neovim role pulls in npm, which we do not want anywhere on this host.
  roles.neovim.enable = lib.mkForce false;

  # Host-side hermes user/group: owns the bind-mounted state on disk and lets
  # regular users in the hermes group share the workspace.
  #
  # The uid/gid are pinned here and the container mirrors these SAME values by
  # reference (see hermesUid/hermesGid below), so host and container agree on
  # the numeric owner. This is required because privateUsers = "no" shares the
  # uid namespace 1:1, yet host and container are independent NixOS systems that
  # would otherwise each auto-allocate a DIFFERENT hermes uid (they drifted to
  # 994 vs 999 — and 999 collides with the host's dhcpcd). Auto-allocated system
  # uids are assigned at activation, so they are null at eval time and cannot be
  # read across the container boundary; pinning is the only way both sides can
  # share one value. This host's hermes already owns its state at 994:992, so we
  # adopt those — the specific number is incidental; what matters is one
  # definition, referenced, not duplicated.
  #
  # createHome + homeMode 2770 are REQUIRED: on a fresh deploy /var/lib/hermes
  # may not exist host-side, and systemd-nspawn would auto-create the bind
  # source as root:root → the agent (hermes) couldn't write its state. createHome
  # makes activation create it owned hermes:hermes BEFORE the container binds it.
  # homeMode 2770 (setgid + group-rwx) is essential: the default 0700 would lock
  # the hermes group out, so users like doot could not access the shared state.
  users = {
    groups.hermes.gid = hermesGid;
    users.hermes = {
      isSystemUser = true;
      uid = hermesUid;
      group = "hermes";
      home = "/var/lib/hermes";
      createHome = true;
      homeMode = "2770";
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

    # Ephemeral root: the container boots from an empty root filesystem each
    # start, so its /var/lib/nixos uid-map is regenerated from THIS config every
    # time. Without this, the map persists the uid the container first
    # auto-allocated (999) and NixOS honours that existing entry over the
    # declared uid = 994 below — so the pin never takes effect and the agent
    # can't read its host-owned state. Ephemeral makes the declarative uid
    # authoritative on every boot. The agent's real state is the bind-mounted
    # /var/lib/hermes (below), which is unaffected; nothing the container writes
    # to its own root needs to survive a restart — a containment plus.
    ephemeral = true;

    # One shared namespace for gateway + TUI. Egress policy is enforced
    # host-side (below), where the agent cannot reach or rewrite it.
    privateNetwork = true;
    inherit hostAddress localAddress;

    # Shared uid namespace (privateUsers = "no", the default): container uids
    # equal host uids. This is REQUIRED for `machinectl shell` to allocate a PTY
    # into the container — a private user namespace ("pick") makes machined fail
    # with "Failed to get shell PTY: Access denied", breaking the interactive
    # TUI below. With shared uids, the host and container hermes are pinned to
    # the same uid/gid (below), so bind-mounted state ownership is coherent
    # without any id-mapping.
    #
    # Containment note: a container escape therefore lands as host uid `hermes`
    # (not an unmapped high uid). The systemd-nspawn boundary still provides a
    # separate network/mount/pid namespace, capability drop, and the host-side
    # egress isolation below — the agent is unprivileged on the host either way.

    # Thread the flake inputs + the shared hermes uid/gid into the container's
    # nested evaluation. The uid/gid mirror the host's hermes user (defined
    # once, above) so the container's hermes resolves to the SAME numeric owner
    # as the bind-mounted state on the host. (Containers don't inherit host
    # specialArgs, so these must be passed explicitly.)
    specialArgs = {inherit inputs hermesUid hermesGid;};

    # Shared state + the secret, bound from the host. Shared uids make ownership
    # map 1:1, so plain bindMounts suffice (no id-mapping needed). The state dir
    # is read-WRITE (the agent persists sessions/skills/config there); the secret
    # is read-only. NB: bindMounts default isReadOnly = true, so the state mount
    # must set it false explicitly.
    bindMounts = {
      "/var/lib/hermes" = {
        hostPath = "/var/lib/hermes";
        isReadOnly = false;
      };
      "/var/lib/hermes-secrets/agent.env" = {
        hostPath = config.sops.templates."hermes-agent.env".path; # /run/...
        isReadOnly = true;
      };
      # Read-only: the agent uses the key, it does not manage it.
      ${agentKeyPath} = {
        hostPath = config.sops.secrets.hermes-ssh-key.path; # /run/...
        isReadOnly = true;
      };
    };

    config = {
      config,
      lib,
      pkgs,
      inputs,
      hermesUid,
      hermesGid,
      ...
    }: let
      # Built from the container's own pkgs so the plugin matches the
      # interpreter the agent actually runs.
      sessionLeases = pkgs.callPackage ../../modules/hermes-session-leases {};
    in {
      imports = [
        inputs.hermes-agent.nixosModules.default
        inputs.priv.nixosModules.hermesPriv

        # The container intentionally does not inherit anything from the host,
        # so explicitly include some very basic imports.
        ../../modules/shell-defaults
      ];

      # The neovim config pulls in undesired dependencies.
      roles.shellDefaults.editor = "vim";

      # Pin the container's hermes user/group to the SAME ids as the host's
      # (threaded in via specialArgs above). The hermes-agent module declares
      # this user with isSystemUser and no uid, so it would otherwise auto-
      # allocate a different number than the host — leaving the bind-mounted
      # state (owned by the host's hermes) unreadable to the agent. mkForce
      # because the module already defines the user/group.
      users.users.hermes.uid = lib.mkForce hermesUid;
      users.groups.hermes.gid = lib.mkForce hermesGid;

      # No nix daemon → no `nix build`/`nix-shell`/`nix run` self-install.
      # No python/pip/uv on PATH either. This is the package-install lockdown.
      nix.enable = false;

      networking = {
        # DNS goes to the host's systemd-resolved stub on the veth (hostAddress),
        # which resolves on the container's behalf. The container needs ZERO
        # direct LAN access for DNS — it only ever talks to the host, which then
        # queries upstream. The LAN resolvers stay blocked by the deny rules.
        useHostResolvConf = false;
        nameservers = [hostAddress];
        # Leaf system: it does not manage the host firewall.
        firewall.enable = lib.mkForce false;
      };
      environment.systemPackages = with pkgs; [
        github-cli
        forgejo-cli
        alejandra
        bat
        delta
        devenv # This is probably a dumb idea...
        eza
        fd
        file
        htop
        jq
        ncdu
        nix-tree # TUI to browse nix dependency graph/sizes
        nix-sweep # CLI to analyse nix store usage
        nvd
        ripgrep
        tmux
        vim
        yq
        git-who # `git who` command to show blame for file trees
        cachix
        tree
        btop
        dig
        iperf3
        mcp-nixos
        shellcheck
        lua-language-server
        basedpyright
        pyright
        nixd
      ];

      programs = {
        git = {
          enable = true;
          config = {
            user = {
              name = "hermes-agent";
              email = agentEmail;
              signingKey = agentKeyPath;
            };

            gpg = {
              # ssh format: the same key already authenticates the Forgejo push,
              # and no gpg keyring exists in the container.
              format = "ssh";
              ssh.allowedSignersFile = toString allowedSigners;
            };

            commit.gpgSign = true;
            tag.gpgSign = true;
          };
        };

        ssh.extraConfig = ''
          Host ${forgejoSshHost}
            Hostname nsf.jhauschildt.com
            User forgejo
            IdentityFile ${agentKeyPath}
            IdentitiesOnly yes
            AddKeysToAgent yes
        '';
      };

      # ── THE Hermes config — single source of truth, defined once, here ────
      services.hermes-agent = {
        enable = true;

        # CLI on the container PATH + HERMES_HOME exported, so the machinectl
        # TUI wrapper and the gateway share one state dir.
        addToSystemPackages = true;

        # Rendering `settings` into configFile makes Nix the sole owner of
        # config.yaml: the module installs it verbatim instead of deep-merging,
        # so a key deleted here disappears on rebuild. The merge path is
        # additive-only and strands removed keys (and any runtime TUI writes)
        # on disk forever. Costs the module's implicit terminal.cwd default,
        # which is why it is set explicitly below.
        configFile =
          pkgs.writeText "hermes-config.yaml"
          (builtins.toJSON config.services.hermes-agent.settings);

        settings = {
          # Hand-bumped: managed installs refuse the config writes that would
          # otherwise advance this on update.
          _config_version = 38;

          model = {
            provider = "copilot";
            default = "claude-opus-5";
          };
          context = {
            engine = "lcm";
          };
          plugins.enabled = [
            "hermes-lcm"
          ];
          memory = {
            memory_enabled = true;
            user_profile_enabled = true;
            # Holographic provider: a bundled, fully-local memory plugin storing
            # structured facts in SQLite at $HERMES_HOME/memory_store.db. Runs
            # alongside built-in memory (never replaces it), adds entity
            # resolution, trust scoring, and HRR compositional retrieval. Needs
            # no API key, no LLM, and no network — the embedding/HRR math is the
            # only dependency, satisfied by numpy in extraPythonPackages below.
            provider = "holographic";
            user_char_limit = 2750;
          };
          display = {
            skin = "slate";
            compact = true;
            show_cost = true;
            timestamps = true;
            interface = "tui";
            show_reasoning = true;
            reasoning_full = true;
            sections.thinking = "expanded";
            memory_notifications = "verbose";
          };
          privacy.redact_pii = true;
          dashboard.theme = "ember";
          agent = {
            environment_hint = "You are running inside a locked-down NixOS container: no nix daemon, no package managers, and network access restricted to the internet only (no local network).";
            reasoning_effort = "xhigh";
          };
          terminal.cwd = "/var/lib/hermes/workspace";

          # Plugin discovery is opt-in: a plugin on disk stays inert until named
          # here. session-leases is installed via extraPlugins below.
          plugins.enabled = ["session-leases"];
        };

        mcpServers = {
          nixos = {
            command = "mcp-nixos";
            args = ["--"];
          };
          # TODO: Re-enable after memory issues are sorted out. Each spawned process consumes 4-8 GB of memory, even before it does anything...
          # TODO: Once memory issues are sorted out, centralize these MCPs so that only one instance is needed and connect via http
          # devenv = {
          #   # type = "stdio";
          #   command = "devenv";
          #   args = ["--from" "github:doot/nixos-config" "mcp"];
          #   # env = {
          #   #   DEVENV_ROOT = "/var/lib/hermes/workspace/nixos-config";
          #   # };
          # };
        };

        # Non-secret env for the agent.
        environment = {
          # Points the obsidian skill at the vault clone (homelab/hermes-vault)
          # so it resolves without a hardcoded path.
          OBSIDIAN_VAULT_PATH = "/var/lib/hermes/workspace/hermes-vault";

          # ntfy comms channel. The bundled ntfy plugin auto-enables once
          # NTFY_TOPIC is set; the token (the only secret) comes from the sops
          # template. NTFY_TOPIC must match nmd's auth-access ACL
          # (systems/nix-media-docker/default.nix).
          #
          # NTFY_ALLOWED_USERS is required: the gateway is fail-closed and the
          # ntfy adapter keys inbound identity on the topic name, so without it
          # every inbound message is dropped (outbound still works).
          NTFY_SERVER_URL = "https://ntfy.${(import ../../common/network.nix).hosts.nix-media-docker.fqdn}";
          NTFY_TOPIC = "hermes-agent";
          NTFY_ALLOWED_USERS = "hermes-agent";
          NTFY_HOME_CHANNEL = "hermes-agent";

          # Observability endpoints (all on nmd, whole-host allowlisted). Grafana
          # needs GRAFANA_TOKEN (sops template); Prometheus + Loki are anon-read.
          GRAFANA_URL = "https://grafana.${nmdFqdn}";
          PROMETHEUS_URL = "https://prom.${nmdFqdn}";
          LOKI_URL = "http://${nmdFqdn}:3100";
        };

        # sops-nix–rendered env file, bind-mounted read-only from the host (see
        # bindMounts above). Decrypted to /run tmpfs (root 0400); values encrypted
        # in the priv overlay (nixos-config-priv/secrets/secrets.yaml).
        #
        # For ntfy, add NTFY_TOKEN to the "hermes-agent.env" sops template in the
        # priv overlay (via config.sops.placeholder); it must equal the tk_... in
        # nmd's NTFY_AUTH_TOKENS for user hermes.
        environmentFiles = ["/var/lib/hermes-secrets/agent.env"];

        # No compilers or package managers visible to the agent.
        extraPackages = [];

        # Hermes persists session transcripts but not which sessions had a
        # terminal attached, so a reboot of this host loses the working set
        # while keeping every transcript. This records that fact; the packaged
        # store path keeps the hooks outside the agent's own writable plugin dir.
        extraPlugins = [sessionLeases];

        # numpy enables the holographic memory provider's full HRR (Holographic
        # Reduced Representation) retrieval — the reason/related/contradict
        # compositional queries. Without it the provider still loads but
        # silently degrades to FTS5 keyword search only. This lands on the
        # agent's PYTHONPATH (not the sealed venv rebuild). numpy ships
        # pre-compiled native (C/Cython) extensions via nixpkgs, so no build
        # toolchain or package manager is exposed to the agent at runtime.
        extraPythonPackages = [pkgs.python312Packages.numpy];

        extraPlugins = [
          (pkgs.fetchFromGitHub {
            owner = "stephenschoettler";
            repo = "hermes-lcm";
            rev = "v0.20.0";
            hash = "sha256-yJ1Nn+su7YbKd+cgVOizXChzLbKHqTprSprF1p9/HYk=";
          })
        ];
      };

      # Defense-in-depth on top of the module baseline (which already sets
      # NoNewPrivileges, ProtectSystem=strict, PrivateTmp): drop all capabilities
      # and add kernel/proc protections. Egress filtering lives host-side.
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

  # Host DNS via systemd-resolved, which also serves the container. The agent
  # sends DNS to the stub on the veth host address (hostAddress); resolved
  # forwards to the host's own upstreams and returns the answer. This is host
  # INPUT — the container never forwards to / reaches a LAN resolver itself, so
  # it needs ZERO LAN access for name resolution. resolved's stub sets
  # IP_FREEBIND, so it binds hostAddress even though the veth only appears once
  # the container starts (no boot-ordering workaround needed). Upstreams are
  # learned automatically from dhcpcd. This host exists solely to run the agent
  # container, so making resolved the host resolver is intentional.
  services.resolved = {
    enable = true;
    settings.Resolve.DNSStubListenerExtra = [hostAddress];
  };

  # ── Host-side egress policy (the agent cannot reach or change this) ───────
  networking = {
    # NAT the container link out the uplink (enables ip_forward + masquerade).
    nat = {
      enable = true;
      inherit externalInterface;
      internalInterfaces = [vethHost];
    };

    firewall = {
      # Let the container reach the host's DNS stub on the veth (this is host
      # INPUT, not LAN forwarding). DNS is the ONLY host service exposed.
      interfaces.${vethHost} = {
        allowedUDPPorts = [53];
        allowedTCPPorts = [53];
      };

      # LAN isolation for the container's forwarded traffic, in a dedicated
      # `hermes-egress` chain so the rule order is explicit and self-contained
      # (no dependence on insertion position vs. the nat module's FORWARD jump):
      # the chain is evaluated top-to-bottom — ACCEPT the allowlisted hosts,
      # then DROP the private ranges, then fall through to internet. With
      # allowedInternalHosts empty (default), the container reaches the internet
      # and nothing on the LAN. Raw iptables because the typed extraForwardRules
      # needs the nftables backend this host doesn't run (see PR notes).
      # Verify after rebuild: `iptables -L hermes-egress -n`.
      extraCommands = ''
        # create-or-flush — idempotent across firewall reloads
        iptables -N hermes-egress 2>/dev/null || iptables -F hermes-egress
        ${egressRules}
        # jump from FORWARD exactly once (guard against stacking on reload)
        iptables -C FORWARD -i ${vethHost} -j hermes-egress 2>/dev/null \
          || iptables -A FORWARD -i ${vethHost} -j hermes-egress
      '';

      extraStopCommands = ''
        iptables -D FORWARD -i ${vethHost} -j hermes-egress 2>/dev/null || true
        iptables -F hermes-egress 2>/dev/null || true
        iptables -X hermes-egress 2>/dev/null || true
      '';
    };
  };

  environment.systemPackages = [
    # Interactive TUI for regular users via `machinectl shell` into the container.
    hermesTui
  ];

  # polkit MUST be enabled for a non-root user (in wheel) to open the shell
  # without an interactive auth prompt. The rule is scoped to the `hermes`
  # machine specifically (via action.lookup("machine")) so it does not grant
  # passwordless shell into any other machine registered with systemd-machined.
  security.polkit = {
    enable = true;
    extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id == "org.freedesktop.machine1.shell" &&
            action.lookup("machine") == "hermes" &&
            subject.isInGroup("wheel")) {
          return polkit.Result.YES;
        }
      });
    '';
  };
}
