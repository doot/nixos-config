# Common defaults for Arion/Docker services
{
  # Default timezone
  tz = "America/Los_Angeles";

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
