{lib, ...}: {
  image.modules.proxmox = {
    imports = [../../modules/proxmox-no-channel.nix];
    boot.loader.systemd-boot.enable = lib.mkForce false;
    # Classic bash-based initrd. systemd-initrd (the nixos-unstable default) fails
    # switch-root on this image — the CHASE_PROHIBIT_SYMLINKS path lookup in
    # systemd 260.x can't find a usable init. The bash initrd has no such logic.
    boot.initrd.systemd.enable = lib.mkForce false;
    proxmox = {
      qemuConf = {
        name = "nix-slopfucker";
        cores = 2;
        memory = 4096;
        additionalSpace = "2G";
        # virtio0 = "local-zfs:vm-500-disk-0";
        virtio0 = "big-fucking-lvm-1:vm-130-disk-0";
        scsihw = "virtio-scsi-single";
      };
      cloudInit.defaultStorage = "local-zfs";
    };
    users.users.root.password = "nixos"; # Initial password, change after first login
    services.getty.autologinUser = lib.mkForce "root";
    services.qemuGuest.enable = true;
  };
}
