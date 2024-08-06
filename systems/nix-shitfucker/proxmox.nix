{
  lib,
  modulesPath,
  ...
}: {
  imports = [
    (modulesPath + "/virtualisation/qemu-guest-agent.nix")
  ];
  proxmox = {
    qemuConf = {
      name = "nix-shitfucker";
      cores = 4;
      memory = 12288;
      additionalSpace = "50G";
      virtio0 = "big-fucking-lvm-1:vm-130-disk-0";
    };
  };

  services.qemuGuest.enable = true;

  users.users.root.password = "nixos"; # Initial password, must be changed after first login
  services.getty.autologinUser = lib.mkForce "root"; # Auto-login from proxmox console

  proxmox.qemuConf.scsihw = "virtio-scsi-single";
}
