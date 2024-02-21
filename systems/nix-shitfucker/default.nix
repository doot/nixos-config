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
  ];

 boot.kernelPackages = pkgs.linuxPackages_latest;

  system.stateVersion = "23.11";

  services.qemuGuest.enable = true;

  users.users.root.password = "nixos";  # Initial password, must be changed after first login
  services.getty.autologinUser = lib.mkDefault "root";
}
