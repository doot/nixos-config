{
  config,
  pkgs,
  lib,
  ...
}: {
  environment.systemPackages = with pkgs; [
    alejandra
    dig
    eza
    fd
    file
    fzf
    git
    iperf3
    jq
    lsof
    ncdu
    neovim
    nvd
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
      "-L" # print build logs
      "--recreate-lock-file"
      "--override-input"
      "priv"
      "/home/doot/nixos-config-priv"
    ];
    flake = "/home/doot/nixos-config#";
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
        git clone --recurse-submodules https://github.com/doot/dotfiles.git /home/doot/.dotfiles
        cd /home/doot/.dotfiles
        git remote remove origin
        git remote add origin git@github.com:doot/dotfiles.git
        echo ":/"
      fi
    '';
  };
}
