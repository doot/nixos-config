{
  lib,
  pkgs,
  modulesPath,
  ...
}: {
  imports = [
    (modulesPath + "/virtualisation/qemu-guest-agent.nix")
    (modulesPath + "/virtualisation/proxmox-image.nix")
    ./hardware-configuration.nix # Include the results of the hardware scan.
  ];

  environment.systemPackages = with pkgs; [
    distrobox
    emacs
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
  ];

  fonts.packages = with pkgs; [
    nerdfonts # needed for waybar
    noto-fonts
    noto-fonts-cjk
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

    eternal-terminal.enable = true;

    emacs.enable = true;
  };

  users.users.root.password = "nixos"; # Initial password, must be changed after first login
  services.getty.autologinUser = lib.mkDefault "doot";

  programs = {
    hyprland = {
      # Install the packages from nixpkgs
      enable = true;
      # Whether to enable XWayland
      xwayland.enable = true;
    };

    waybar.enable = true;

    thunar.enable = true;
  };

  services.displayManager = {
    enable = true;

    sddm = {
      enable = true;

      wayland.enable = true;

      settings.Users.HideUsers = "docker-media";
    };

    defaultSession = "hyprland";
  };

  services.xserver = {
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

  programs.firefox.enable = true;
  programs.firefox.package = pkgs.firefox-bin;

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
        flags = ["--all"];
      };
    };
  };
}
