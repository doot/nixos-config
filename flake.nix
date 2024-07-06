{
  description = "fuck you, that's who";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05-small";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

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

    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };
  };

  outputs = {
    # deadnix: skip
    self,
    nixpkgs,
    nixpkgs-unstable,
    arion,
    alejandra,
    priv,
    nixos-generators,
    home-manager,
  }: {
    # Set the formatter for `nix fmt`
    formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.alejandra;

    nixosConfigurations.nix-media-docker = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./common
        ./common/users
        ./common/monitoring
        ./systems/nix-media-docker
        arion.nixosModules.arion
        priv.nixosModules.stub

        # Pin nixpkgs to the one used to build the system
        {nix.registry.nixpkgs.flake = nixpkgs;}

        # Overlay nixpkgs-unstable, so that select unstable packages can be used
        {
          nixpkgs.overlays = [
            (_: _: {
              unstable = import nixpkgs-unstable {
                system = "x86_64-linux";
              };
            })
          ];
        }
      ];
    };

    nixosConfigurations.nix-shitfucker = nixpkgs-unstable.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./common
        ./common/users
        ./systems/nix-shitfucker
        ./common/sunshine.nix
        # Pin nixpkgs to the one used to build the system
        {nix.registry.nixpkgs.flake = nixpkgs-unstable;}
        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.users.doot = import ./common/home/desktop.nix;
        }
      ];
    };

    # Generate proxmox image via `nix build .#nix-shitfucker`
    packages.x86_64-linux = {
      nix-shitfucker = nixos-generators.nixosGenerate {
        system = "x86_64-linux";
        modules = [
          ./common
          ./common/users
          ./systems/nix-shitfucker
          ./systems/nix-shitfucker/proxmox.nix
        ];
        format = "proxmox";
      };
    };
  };
}
