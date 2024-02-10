{
  description = "fuck you, that's who";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-23.11-small";

    alejandra = {
      url = "github:kamadorueda/alejandra/3.0.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    arion = {
      url = "github:hercules-ci/arion";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    priv = {
      url = "path:./priv";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    arion,
    alejandra,
    priv,
  }: {

    # Set the formatter for `nix fmt`
    formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.alejandra;

    nixosConfigurations.nix-media-docker = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./common
        ./common/users
        ./systems/nix-media-docker
        arion.nixosModules.arion
        priv.nixosModules.stub
        # Pin nixpkgs to the one used to build the system
        {nix.registry.nixpkgs.flake = nixpkgs;}
      ];
    };
  };
}
