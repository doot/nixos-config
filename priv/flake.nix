{
  description = "stub";

  inputs = {};

  outputs = {
    # deadnix: skip
    self,
    # deadnix: skip
    nixpkgs,
  }: {
    nixosModules = {
      stub = _: {};
      hermesPriv = _: {};
      borgKey = _: {};
    };
  };
}
