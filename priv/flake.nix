{
  description = "stub";

  inputs = {};

  outputs = {
    # deadnix: skip
    self,
    # deadnix: skip
    nixpkgs,
  }: {
    nixosModules.stub = _: {};
    # No-op counterpart to the private overlay's hermesSoul module. Present so
    # the public flake evaluates (nix flake check) with the stub priv input;
    # the real module that lands SOUL.md is swapped in via --override-input priv.
    nixosModules.hermesSoul = _: {};
  };
}
