{
  description = "fuck you, that's who";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05-small";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable-small";

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
  } @ inputs: let
    inherit (self) outputs;
    host_nmd = "nix-media-docker";
    host_nsf = "nix-shitfucker";
  in {
    # Set the formatter for `nix fmt`
    formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.alejandra;

    nixosConfigurations = {
      ${host_nmd} = let
        hostname = host_nmd;
      in
        nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = {
            inherit inputs outputs hostname;
          };
          modules = [
            ./systems/${hostname}
            ./common
            ./common/users
            ./common/monitoring
            ./common/alloy
            arion.nixosModules.arion
            priv.nixosModules.stub

            # Pin nixpkgs to the one used to build the system
            {nix.registry.nixpkgs.flake = nixpkgs;}

            # Overlay nixpkgs-unstable, so that select unstable packages can be used
            {
              # networking.hostName = "nix-media-docker";
              nixpkgs.overlays = [
                (_: prev: {
                  unstable = import nixpkgs-unstable {
                    inherit (prev) system;
                  };
                })
              ];
            }
          ];
        };

      ${host_nsf} = let
        hostname = host_nsf;
      in
        nixpkgs-unstable.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = {
            inherit inputs outputs hostname;
          };
          modules = [
            ./systems/${hostname}
            ./common
            ./common/users
            ./common/sunshine.nix
            ./common/alloy
            # Pin nixpkgs to the one used to build the system
            {nix.registry.nixpkgs.flake = nixpkgs-unstable;}
            home-manager.nixosModules.home-manager
            {
              home-manager = {
                useGlobalPkgs = true;
                useUserPackages = true;
                users.doot = import ./common/home/desktop.nix;
              };
            }
            # Overlay nixpkgs-unstable. This host is based off of unstable, but the overlay should be available uniformly
            # TODO: Figure out a way to deduplicate this so it's the default for all host configs
            {
              # networking.hostName = "nix-media-docker";
              nixpkgs.overlays = [
                (_: prev: {
                  unstable = import nixpkgs-unstable {
                    inherit (prev) system;
                  };
                })
              ];
            }
          ];
        };
    };

    # Generate proxmox image via `nix build .#nix-shitfucker`
    packages.x86_64-linux = {
      ${host_nsf} = let
        hostname = host_nsf;
      in
        nixos-generators.nixosGenerate {
          system = "x86_64-linux";
          specialArgs = {
            inherit inputs outputs hostname;
          };
          modules = [
            ./systems/${hostname}
            ./common
            ./common/users
            ./systems/nix-shitfucker/proxmox.nix
            # Overlay nixpkgs-unstable. This host is based off of unstable, but the overlay should be available uniformly
            # TODO: Figure out a way to deduplicate this so it's the default for all host configs
            {
              # networking.hostName = "nix-media-docker";
              nixpkgs.overlays = [
                (_: prev: {
                  unstable = import nixpkgs-unstable {
                    inherit (prev) system;
                  };
                })
              ];
            }
          ];
          format = "proxmox";
        };
    };
  };
}
