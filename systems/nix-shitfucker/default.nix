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
    python3

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

  users.users.root.password = "nixos";  # Initial password, must be changed after first login
  services.getty.autologinUser = lib.mkDefault "doot";
}
