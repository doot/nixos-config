{lib, ...}: {
  image.modules.proxmox = {
    boot.loader.systemd-boot.enable = lib.mkForce false;
    proxmox = {
      qemuConf = {
        name = "nix-shitfucker";
        cores = 4;
        memory = 12288;
        additionalSpace = "50G";
        virtio0 = "big-fucking-lvm-1:vm-130-disk-0";
        scsihw = "virtio-scsi-single";
      };
    };
    users.users.root.password = "nixos"; # Initial password, must be changed after first login
    services.getty.autologinUser = lib.mkForce "root"; # Auto-login from proxmox console, may be needed for first boot?
    services.qemuGuest.enable = true;
  };
}
