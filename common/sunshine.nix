# Still a few things are not ideal yet, but it's still better than traditional VNC:
#   - Requires logging into a graphical session some other way first (physically or through vnc)
#   - Uses user systemd unit
#   - Session is shared with above mentioned session, so it's a little wierd to set a resolution that is ideal for both
#   - Maybe look into using a separate, dummy, display?
{pkgs, ...}: {
  users.users.doot.extraGroups = [
    "input" # sunshine
    "video" # sunshine
    "sound" # sunshine
  ];

  services.sunshine = {
    autoStart = true;
    enable = true;
    openFirewall = true;

    # Temporary to fix build
    package = pkgs.sunshine.override {boost = pkgs.boost186;};
  };

  # services.udev.extraRules = ''
  #   KERNEL=="uinput", SUBSYSTEM=="misc", OPTIONS+="static_node=uinput", TAG+="uaccess"
  # '';

  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  security.rtkit.enable = true;
}
