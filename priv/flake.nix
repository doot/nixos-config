{
  description = "stub";

  inputs = {};

  outputs = {
    self,
    nixpkgs,
  }: {
    nixosModules.stub = {...}: {
    };
  };
}
