{
  description = "fuck you, that's who";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-23.11";

    alejandra = {
      url = "github:kamadorueda/alejandra/3.0.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    arion = {
      url = "github:hercules-ci/arion";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    arion,
    alejandra,
  }: {
    formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.alejandra;

    nixosConfigurations.nix-media-docker = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./common
        ./common/users
        ./systems/nix-media-docker
        arion.nixosModules.arion
      ];
    };
  };
}
