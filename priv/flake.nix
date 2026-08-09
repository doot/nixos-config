{
  description = "stub";

  inputs = {};

  outputs = {
    # deadnix: skip
    self,
    # deadnix: skip
    nixpkgs,
  }: {
    # No-ops mirroring the real private overlay's outputs. CI evaluates against
    # these (--override-input priv ./priv); the deploy override supplies the
    # real per-host bundles.
    nixosModules = {
      slopPriv = _: {};
      nmdPriv = _: {};
      nsfPriv = _: {};
      stub = _: {};
      hermesPriv = _: {};
      borgKey = _: {};
    };
  };
}
