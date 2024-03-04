# Sets up Sunshine, adapted from example: https://github.com/PierreBeucher/Cloudy-Sunshine/blob/7c83431b7531e3a0833d33851390b8c91387b2f3/provision/modules/sunshine.nix
# Still a few things are not ideal yet, but it's still better than traditional VNC:
#   - Requires logging into a graphical session some other way first (physically or through vnc)
#   - Uses user systemd unit
#   - Session is shared with above mentioned session, so it's a little wierd to set a resolution that is ideal for both
#   - Maybe look into using a separate, dummy, display?
{
  config,
  lib,
  pkgs,
  modulesPath,
  self,
  ...
}: let
in {
  environment.systemPackages = with pkgs; [
    sunshine
  ];

  users.users.doot.extraGroups = [
    "input" # sunshine
    "video" # sunshine
    "sound" # sunshine
  ];

  security.wrappers.sunshine = {
    owner = "root";
    group = "root";
    capabilities = "cap_sys_admin+p";
    source = "${pkgs.sunshine}/bin/sunshine";
  };
  # Inspired from https://github.com/LizardByte/Sunshine/blob/5bca024899eff8f50e04c1723aeca25fc5e542ca/packaging/linux/sunshine.service.in
  systemd.user.services.sunshine = {
    enable = true;
    description = "Sunshine server";
    wantedBy = ["graphical-session.target"];
    startLimitIntervalSec = 500;
    startLimitBurst = 5;
    partOf = ["graphical-session.target"];
    wants = ["graphical-session.target"];
    after = ["graphical-session.target"];

    serviceConfig = {
      ExecStart = "${config.security.wrapperDir}/sunshine";
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };
  # simulate input
  boot.kernelModules = ["uinput"];
  services.udev.extraRules = ''
    KERNEL=="uinput", SUBSYSTEM=="misc", OPTIONS+="static_node=uinput", TAG+="uaccess"
  '';
  networking.firewall = {
    allowedTCPPorts = [
      47984 # HTTPS
      47989 # HTTP/base
      47990 # Web
      48010 # RSTP
    ];
    allowedUDPPorts = [
      47998 # Video
      47999 # Control
      48000 # Audio
      # 48002  # Mic (unused)
    ];
  };
  hardware.opengl = {
    enable = true;
    driSupport = true;
    driSupport32Bit = true;
  };

  security.rtkit.enable = true;
}
