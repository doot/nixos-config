# Common defaults for Arion/Docker services
{
  # Default timezone
  tz = "America/Los_Angeles";

  # Default user/group IDs (strings for Docker env var compatibility)
  puid = "1029";
  pgid = "100";

  # Generates a standard curl-based healthcheck for the given port.
  mkHealthcheck = port: {
    test = ["CMD-SHELL" "curl --fail localhost:${toString port}/ || exit 1"];
    interval = "30s";
    timeout = "15s";
    retries = 3;
    start_period = "1m";
  };

  # Default out.service overrides with sensible defaults.
  # Usage: out.service = common.outDefaults // { cpu_shares = 2048; };
  # Or just: out.service = common.outDefaults;
  outDefaults = {
    pull_policy = "always";
    cpu_shares = 256;
    mem_limit = "2g";
    memswap_limit = "2g";
  };
}
