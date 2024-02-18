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
    #   # ./hardware-configuration.nix # Include the results of the hardware scan.
  ];
  proxmox.qemuConf.name = "nix-shitfucker";
  networking.hostName = "nix-shitfucker";

  environment.systemPackages = with pkgs; [
    distrobox
    python3
  ];

  system.stateVersion = "23.11";

  proxmox.qemuConf.cores = 4;
  proxmox.qemuConf.memory = 12288;
  proxmox.qemuConf.additionalSpace = "30G";
  proxmox.qemuConf.virtio0 = "big-fucking-lvm-1:vm-130-disk-0";

  services.qemuGuest.enable = true;

  users.users.root.password = "nixos";  # Initial password, must be changed after first login
  services.getty.autologinUser = lib.mkDefault "root";
}
