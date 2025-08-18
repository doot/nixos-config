{
  lib,
  pkgs,
  modulesPath,
  config,
  ...
}: {
  imports = [
    (modulesPath + "/virtualisation/qemu-guest-agent.nix")
    (modulesPath + "/virtualisation/proxmox-image.nix")
    ./hardware-configuration.nix # Include the results of the hardware scan.
  ];

  environment.systemPackages = with pkgs; [
    distrobox
    kitty
    podman-compose
    python3
    swww
    waypaper
    wl-clipboard
    wofi

    # are these necessary?
    meson
    wayland-protocols
    wayland-utils
    wlroots
    xdg-desktop-portal-gtk
    xdg-desktop-portal-hyprland

    # notification daemon
    dunst
    libnotify

    # try out
    foot
    ghostty
  ];

  fonts.packages = with pkgs; [
    # nerdfonts # needed for waybar
    nerd-fonts.fira-code
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-emoji
    liberation_ttf
    fira-code
    fira-code-symbols
    mplus-outline-fonts.githubRelease
    dina-font
    proggyfonts
    font-awesome
  ];

  boot.kernelPackages = pkgs.linuxPackages_latest;

  system.stateVersion = "23.11";

  services = {
    qemuGuest.enable = true;

    emacs = {
      enable = true;
      package = pkgs.emacs30;
    };

    getty.autologinUser = lib.mkDefault "doot";

    immich = {
      enable = true;
      host = "192.168.1.110";
      openFirewall = true;
      mediaLocation = "/mnt/pictures-nfs/immich/";
      accelerationDevices = null; # `null` gives access to all devices.
    };

    displayManager = {
      enable = true;
      defaultSession = "hyprland";
      sddm = {
        enable = true;
        wayland.enable = true;
        settings.Users.HideUsers = "docker-media";
      };
    };

    xserver = {
      enable = true;
      # dummy screen
      monitorSection = ''
        VendorName     "Unknown"
        HorizSync   30-85
        VertRefresh 48-120

        ModelName      "Unknown"
        Option         "DPMS"
      '';
    };
  };

  users = {
    users = {
      root.password = "nixos"; # Initial password, must be changed after first login
      immich.extraGroups = ["video" "render"]; # Extra immich settings (move into module later)
    };
  };

  programs = {
    hyprland = {
      enable = true;
      xwayland.enable = true;
    };

    waybar.enable = true;

    thunar.enable = true;

    firefox = {
      enable = true;
    };
  };

  virtualisation = {
    containers.enable = true;

    podman = {
      enable = true;
      dockerCompat = true;

      # Required for containers under podman-compose to be able to talk to each other.
      defaultNetwork.settings.dns_enabled = true;

      autoPrune = {
        enable = true;
        dates = "daily";
        flags = ["--all" "--build"];
      };
    };
  };

  networking = {
    firewall.allowedTCPPorts = [
      8765 # wezterm
      config.services.forgejo.settings.server.HTTP_PORT
    ];
  };

  # Enable forgejo service
  roles.forgejo.enable = true;
}
