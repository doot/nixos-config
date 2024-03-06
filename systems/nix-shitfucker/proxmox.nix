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
  ];
  proxmox.qemuConf.name = "nix-shitfucker";

  proxmox.qemuConf.cores = 4;
  proxmox.qemuConf.memory = 12288;
  proxmox.qemuConf.additionalSpace = "30G";
  proxmox.qemuConf.virtio0 = "big-fucking-lvm-1:vm-130-disk-0";

  services.qemuGuest.enable = true;

  users.users.root.password = "nixos"; # Initial password, must be changed after first login
  services.getty.autologinUser = lib.mkForce "root"; # Auto-login from proxmox console
}
