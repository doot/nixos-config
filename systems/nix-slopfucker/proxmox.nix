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
        # cptofs (lkl) fills the image inside a 100M in-process kernel — values above ~10G
        # exhaust that pool and OOM the build. For a larger runtime disk, resize virtio0
        # in Proxmox post-restore (`qm resize <vmid> virtio0 +XG`) and reboot; growPartition
        # + autoResize (hardware-configuration.nix) expand root on next boot automatically.
        additionalSpace = "10G";
        virtio0 = "local-zfs:vm-500-disk-0";
        scsihw = "virtio-scsi-single";
      };
      cloudInit = {
        # Cloud-Init is not used in this case, but setting the storage is required to prevent build failures
        enable = false;
        defaultStorage = "local-zfs";
      };
    };
    users.users.root.password = "nixos"; # Initial password, must be changed after first login
    services.qemuGuest.enable = true;
  };
}
