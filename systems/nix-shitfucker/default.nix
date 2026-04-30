{
  lib,
  pkgs,
  config,
  ...
}: {
  imports = [
    ./hardware-configuration.nix # Include the results of the hardware scan.
  ];

  environment.systemPackages = with pkgs; [
    distrobox
    kitty
    podman-compose
    python3
    awww
    waypaper
    wl-clipboard
    wofi
    immich-cli

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
    noto-fonts-color-emoji
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

    immich = let
      network = import ../../common/network.nix;
    in {
      enable = true;
      host = network.ips.nix-shitfucker;
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

    nextcloud = {
      # TODO: Create a nextcloud module and set up as a nixos container
      # TODO: Migrate from sqlite to postgres
      # TODO: Move to another port, instead of default of 80
      enable = true;
      hostName = "nc.nmd.jhauschildt.com";
      # database.createLocally = true;
      package = pkgs.nextcloud33;
      config = {
        # dbtype = "pgsql";
        dbtype = "sqlite";
        adminpassFile = "/home/doot/secret_test/nextcloud/admin-pass";
      };
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

    # niri.enable = true;
    # Need to get working niri config before we can switch. Default keybindings don't work with RDP and I don't have them memorized.

    # waybar.enable = true;

    thunar.enable = true;

    firefox = {
      enable = true;
    };

    dms-shell = {
      enable = true;
      systemd.enable = true;
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
      config.services.forgejo.settings.server.HTTP_PORT
      80 # nextcloud
    ];
  };

  # Enable forgejo service
  roles.forgejo.enable = true;
}
