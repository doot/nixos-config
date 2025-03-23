{
  config,
  pkgs,
  lib,
  hostname,
  ...
}: {
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
      fzf
      gnumake
      htop
      jq
      ncdu
      unstable.neovim
      nix-inspect # TUI to browse nix config
      nix-tree # TUI to browse nix dependency graph/sizes
      nvd
      ripgrep
      tmux
      vim
      unstable.wezterm
      wget
      yq

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
  };

  services = {
    openssh.enable = true;

    fstrim.enable = true;

    # Entirely disalbe fallback DNS servers in resolved
    resolved.fallbackDns = [];

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
      recommendedZstdSettings = true;
      recommendedOptimisation = true;
    };

    # Enable node-exporter and open port so that prometheus can scrape
    prometheus = {
      exporters = {
        node = {
          enable = true;
          enabledCollectors = ["systemd"];
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
    firewall = {
      allowedTCPPorts = [
        config.services.eternal-terminal.port
      ];
    };
  };

  i18n.defaultLocale = "C.UTF-8";

  nix = {
    settings = {
      experimental-features = ["nix-command" "flakes"];
      trusted-users = ["doot"];
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

    userActivationScripts = {
      # Clone and install dotfiles
      cloneDotfiles = ''
        if [ ! -d "/home/doot/.dotfiles" ]; then
          source ${config.system.build.setEnvironment}
          echo "Cloning dotfiles..."
          git clone --recurse-submodules https://github.com/doot/dotfiles.git /home/doot/.dotfiles
          cd /home/doot/.dotfiles
          git remote remove origin
          git remote add origin git@github.com:doot/dotfiles.git
          echo ":/"
        fi
      '';
    };

    activationScripts = {
      # Clone and symlink nixos-configs
      cloneNixosConfig = ''
        if [ ! -d "/home/doot/nixos-config" ]; then
          source ${config.system.build.setEnvironment}
          echo "Cloning nixos-config..."
          git clone https://github.com/doot/nixos-config.git /home/doot/nixos-config
          cd /home/doot/nixos-config
          git remote remove origin
          git remote add origin git@github.com:doot/nixos-config.git
        fi
        if [ ! -f /etc/nixos/flake.nix ]; then
          echo "Adding symlink to /etc/nixos/flake.nix"
          ln -s /home/doot/nixos-config/flake.nix /etc/nixos/flake.nix
        fi
      '';
    };
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
