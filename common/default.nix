{
  config,
  pkgs,
  lib,
  ...
}: {
  environment.systemPackages = with pkgs; [
    alejandra
    bat
    cmake
    btop
    dig
    eza
    fd
    file
    fzf
    git
    gnumake
    htop
    iperf3
    jq
    lsof
    ncdu
    neovim
    nvd
    psmisc
    ripgrep
    tmux
    vim
    wget
    yq
  ];

  services.openssh.enable = true;
  services.netbird.enable = true;

  environment.variables = {
    EDITOR = "nvim";
    VISUAL = "nvim";
  };
  environment.sessionVariables.EDITOR = "nvim";

  i18n.defaultLocale = "C.UTF-8";

  nix.settings.experimental-features = ["nix-command" "flakes"];

  nix.optimise.automatic = true; # Automatic daily optimisation of nix store

  nix.gc = {
    automatic = true;
    dates = "daily";
    options = "--delete-older-than 7d";
  };

  system.autoUpgrade = {
    enable = true;
    flags = [
      "--update-input"
      "nixpkgs"
      "--commit-lock-file"
      "-L" # print build logs
      "--recreate-lock-file"
    ];
    flake = "github:doot/nixos-config#";
  };

  # Print changes after nixos-rebuild
  system.activationScripts.report-changes = ''
    echo "---------- nvd diff:"
    PATH=$PATH:${lib.makeBinPath [pkgs.nvd pkgs.nix]}
    nvd diff $(ls -dv /nix/var/nix/profiles/system-*-link | tail -2)
    echo "----------"
  '';

  time.timeZone = "America/Los_Angeles";

  # Try out TCP BBR, to see if it improves network throughput/latency
  boot.kernel.sysctl = {
    "net.core.default_qdisc" = "fq";
    "net.ipv4.tcp_congestion_control" = "bbr";
  };

  # Enable node-exporter and open port so that prometheus can scrape
  networking.firewall.allowedTCPPorts = [9002];
  services.prometheus = {
    exporters = {
      node = {
        enable = true;
        enabledCollectors = ["systemd"];
        port = 9002;
      };
    };
  };

  system.userActivationScripts = {
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

  system.activationScripts = {
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
}
