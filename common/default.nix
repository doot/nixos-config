{
  config,
  pkgs,
  lib,
  inputs,
  hostname,
  domain,
  fqdn,
  ...
}: let
  mainUser = config.users.users.doot;
  nixosConfigDir = "${mainUser.home}/nixos-config";
  dotfilesDir = "${mainUser.home}/.dotfiles";

  # Shared factory for repo-clone oneshots.
  # Idempotent: ConditionPathExists skips the unit when `dir` already exists (on
  # every boot and manual systemctl start), so it's always a no-op once cloned.
  # Atomic: clones into a tmpdir and only mv's into place on full success — a
  # partial clone never tricks the condition into a "false already-done" state.
  # All git ops run as root on the root-owned tree before chown so root-git never
  # trips "detected dubious ownership" on the final doot-owned directory.
  mkCloneService = {
    url,
    dir,
    sshRemote,
    cloneArgs ? "",
  }: {
    after = ["network-online.target"];
    wants = ["network-online.target"];
    wantedBy = ["multi-user.target"];
    unitConfig.ConditionPathExists = "!${dir}";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [pkgs.git];
    script = ''
      set -euo pipefail
      tmpdir=$(mktemp -d ${mainUser.home}/.clone.XXXXXXXX)
      trap "rm -rf $tmpdir" EXIT
      target="$tmpdir/repo"

      # network-online.target with scripted dhcpcd doesn't guarantee DNS is up;
      # retry so a transient failure self-heals rather than failing the unit.
      for attempt in $(seq 1 30); do
        rm -rf "$target"
        if git clone ${cloneArgs} ${url} "$target"; then
          break
        fi
        [ "$attempt" -eq 30 ] && { echo "clone of ${dir} failed after 30 attempts" >&2; exit 1; }
        sleep 10
      done

      git -C "$target" remote set-url origin ${sshRemote}

      trap - EXIT
      mv "$target" ${dir}
      chown -R ${mainUser.name}:${mainUser.group} ${dir}
    '';
  };
in {
  environment = {
    systemPackages = with pkgs; [
      alejandra
      bat
      cmake
      delta
      unstable.devenv
      eza
      fd
      file
      unstable.fzf
      gnumake
      htop
      jq
      ncdu
      inputs.neovim-nightly-overlay.packages.${pkgs.stdenv.hostPlatform.system}.default
      nix-inspect # TUI to browse nix config
      nix-tree # TUI to browse nix dependency graph/sizes
      unstable.nix-sweep # CLI to analyse nix store usage
      nvd
      ripgrep
      tmux
      vim
      unstable.wezterm
      wget
      yq
      unstable.git-who # `git who` command to show blame for file trees
      go
      cachix

      # General diagnostic tools
      bcc
      bpftrace
      btop
      dig
      ethtool
      iperf3
      lsof
      nicstat
      psmisc
      sysstat
      tcpdump
      trace-cmd
      traceroute
    ];

    variables = {
      EDITOR = "nvim";
      VISUAL = "nvim";
      DO_NOT_TRACK = 1;
    };

    sessionVariables.EDITOR = "nvim";
  };

  programs = {
    git.enable = true;
    direnv.enable = true;
    bash.completion.enable = true;
    fzf = {
      keybindings = true;
      fuzzyCompletion = true;
    };
    rust-motd = {
      enable = true;
      enableMotdInSSHD = true;
      order = [
        "global"
        "banner"
        "load_avg"
        "memory"
        "filesystems"
        "service_status"
        "last_login"
        "uptime"
      ];
      settings = {
        banner = {
          color = "green";
          command = ''
            cat << EOF
            ########: ##:::: ##:: ######:: ##::: ##::::: #######:: ########: ########:
            ##.....:: ##:::: ##: ##... ##: ##:: ##::::: ##.... ##: ##.....:: ##.....::
            ##::::::: ##:::: ##: ##:::..:: ##: ##:::::: ##:::: ##: ##::::::: ##:::::::
            ######::: ##:::: ##: ##::::::: #####::::::: ##:::: ##: ######::: ######:::
            ##...:::: ##:::: ##: ##::::::: ##. ##:::::: ##:::: ##: ##...:::: ##...::::
            ##::::::: ##:::: ##: ##::: ##: ##:. ##::::: ##:::: ##: ##::::::: ##:::::::
            ##:::::::. #######::. ######:: ##::. ##::::. #######:: ##::::::: ##:::::::
            EOF
          '';
        };
        load_avg = {
          format = "Load (1, 5, 15 min.): {one:.02}, {five:.02}, {fifteen:.02}";
        };
        memory = {
          swap_pos = "beside";
        };
        filesystems = {
          root = "/";
          nix = "/nix";
        };
        service_status = {
          System = "system.slice";
          User = "user.slice";
          Upgrade = "nixos-upgrade.service";
          UpgradeTimer = "nixos-upgrade.timer";
        };
        last_login = {
          doot = 2;
        };
        uptime = {
          prefix = "Up";
        };
      };
    };
  };

  services = {
    angrr = {
      # Automatically remove old GC roots that haven't been touched in the last 14 days
      enable = true;
      settings = {
        period = "14d";
      };
      package = pkgs.unstable.angrr;
    };

    openssh = {
      enable = true;
      settings = {
        AcceptEnv = lib.mkForce ["TERM_PROGRAM" "COLORTERM" "TERM_PROGRAM_VERSION" "TERM WEZTERM_REMOTE_PANE" "GIT_PROTOCOL"];
      };
    };

    fail2ban.enable = true;

    fstrim.enable = true;

    # Entirely disalbe fallback DNS servers in resolved
    resolved.settings.Resolve.FallbackDNS = [];

    netbird = {
      enable = true;
      package = pkgs.unstable.netbird;
    };

    eternal-terminal.enable = true;

    # nginx defaults
    nginx = {
      recommendedProxySettings = true;
      recommendedTlsSettings = true;
      recommendedGzipSettings = true;
      recommendedBrotliSettings = true;
      recommendedOptimisation = true;
    };

    # Enable node-exporter and open port so that prometheus can scrape
    prometheus = {
      exporters = {
        node = {
          enable = true;
          enabledCollectors = ["systemd" "processes" "perf"];
          port = 9002;
          openFirewall = true;
        };
        systemd = {
          enable = true;
          openFirewall = true;
          extraFlags = [
            "--systemd.collector.enable-restart-count"
            "--systemd.collector.enable-ip-accounting"
          ];
        };
      };
    };

    snmpd = {
      enable = true;
      openFirewall = true;
      configText = ''
        sysLocation    rack
        sysContact     Fart <Fart@Fart.org>
        sysServices    72

        # view   systemonly  included   .1.3.6.1.2.1.1
        # view   systemonly  included   .1.3.6.1.2.1.25.1

        # rocommunity my_servers 192.168.0.0/16
        rocommunity public
        dontLogTCPWrappersConnects yes
      '';
    };
  };

  networking = {
    hostName = hostname;
    inherit domain fqdn;
    firewall = {
      allowedTCPPorts = [
        config.services.eternal-terminal.port
        8765 # wezterm
      ];
    };
  };

  i18n.defaultLocale = "C.UTF-8";

  nix = {
    # Use Lix in place of Nix
    # package = pkgs.unstable.lixPackageSets.latest.lix;  # TODO: Temporary disable again, as it is causing issues?

    settings = {
      experimental-features = ["nix-command" "flakes"];
      trusted-users = ["doot"];

      # Get rid of download buffer is full errors
      # download-buffer-size = 524288000;
      # TODO: might not be supported with Lix
      substituters = ["https://nix-community.cachix.org" "https://wezterm.cachix.org"];
      trusted-public-keys = ["nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs=" "wezterm.cachix.org-1:kAbhjYUC9qvblTE+s7S+kl5XM1zVa4skO+E/1IDWdH0="];
    };

    optimise.automatic = true; # Automatic daily optimisation of nix store

    gc = {
      automatic = true;
      options = "--delete-older-than 14d";
    };
  };

  system = {
    autoUpgrade = {
      enable = true;
      flags = [
        "--refresh" # always fetch latest from git repo
        "-L" # print build logs
      ];
      allowReboot = true;
      flake = "github:doot/nixos-config#";
    };

    # Print changes after nixos-rebuild
    activationScripts.report-changes = ''
      echo "---------- nvd diff:"
      PATH=$PATH:${lib.makeBinPath [pkgs.nvd pkgs.nix]}
      nvd diff $(ls -dv /nix/var/nix/profiles/system-*-link | tail -2)
      echo "----------"
    '';

    activationScripts = {
      # Symlink nixos-config flake into /etc/nixos once the repo is present.
      # The clone itself happens in clone-nixos-config.service (after networking).
      cloneNixosConfig = ''
        if [ -d "${nixosConfigDir}" ] && [ ! -f /etc/nixos/flake.nix ]; then
          ln -s ${nixosConfigDir}/flake.nix /etc/nixos/flake.nix
        fi
      '';
    };
  };

  systemd.services = {
    clone-nixos-config =
      mkCloneService {
        url = "https://github.com/doot/nixos-config.git";
        sshRemote = "git@github.com:doot/nixos-config.git";
        dir = nixosConfigDir;
      }
      // {
        description = "Clone nixos-config repository";
        # Also create the /etc/nixos symlink once the clone lands.
        postStart = ''
          [ -f /etc/nixos/flake.nix ] || ln -sf ${nixosConfigDir}/flake.nix /etc/nixos/flake.nix
        '';
      };

    clone-dotfiles =
      mkCloneService {
        url = "https://github.com/doot/dotfiles.git";
        sshRemote = "git@github.com:doot/dotfiles.git";
        dir = dotfilesDir;
        cloneArgs = "--recurse-submodules";
      }
      // {description = "Clone dotfiles repository";};
  };

  time.timeZone = "America/Los_Angeles";

  boot.kernel.sysctl = {
    # Try out TCP BBR, to see if it improves network throughput/latency
    "net.core.default_qdisc" = "fq";
    "net.ipv4.tcp_congestion_control" = "bbr";

    "vm.swappiness" = "1";
  };

  # Power management defaults
  powerManagement = {
    powertop.enable = true;
    cpuFreqGovernor = "powersave"; # Assuming hardware with intel pstates
  };

  # Enable default roles
  roles.alloy.enable = true;
}
