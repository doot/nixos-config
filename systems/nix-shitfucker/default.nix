{
  config,
  lib,
  pkgs,
  modulesPath,
  self,
  ...
}: {
  imports = [
    (modulesPath + "/virtualisation/qemu-guest-agent.nix")
    (modulesPath + "/virtualisation/proxmox-image.nix")
    ./hardware-configuration.nix # Include the results of the hardware scan.
  ];
  networking.hostName = "nix-shitfucker";

  environment.systemPackages = with pkgs; [
    distrobox
    emacs
    kitty
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

  services.qemuGuest.enable = true;

  services.eternal-terminal.enable = true;

  services.emacs.enable = true;

  users.users.root.password = "nixos"; # Initial password, must be changed after first login
  services.getty.autologinUser = lib.mkDefault "doot";

  programs.hyprland = {
    # Install the packages from nixpkgs
    enable = true;
    # Whether to enable XWayland
    xwayland.enable = false;
  };
  programs.waybar.enable = true;
  programs.thunar.enable = true;

  services.displayManager = {
    sddm.wayland.enable = true;
    sddm.settings.Users.HideUsers = "docker-media";
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
}
