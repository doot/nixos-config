{
  description = "fuck you, that's who";

  nixConfig = {
    extra-substituters = [
      "https://cachix.cachix.org"
      "https://wezterm.cachix.org"
    ];
    extra-trusted-public-keys = [
      "cachix.cachix.org-1:eWNHQldwUO7G2VkjpnjDbWwy4KQ/HNxht7H4SSoMckM="
      "wezterm.cachix.org-1:kAbhjYUC9qvblTE+s7S+kl5XM1zVa4skO+E/1IDWdH0="
    ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05-small";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable-small";

    alejandra = {
      url = "github:kamadorueda/alejandra/4.0.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    arion = {
      url = "github:hercules-ci/arion";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    priv = {
      # TODO: For some reason the relative path stopped working only in the nix-flake-update github action
      # It works fine locally on nix 2.24.12, maybe nix-flake-update was updated to a newer version?
      # I am not sure why this broke, but for now setting the url to the github repo + directory with the sub flake seems to work :/
      # url = "path:./priv";
      url = "github:doot/nixos-config?dir=priv";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };

    wezterm = {
      url = "github:wezterm/wezterm?dir=nix";
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
    domain = "jhauschildt.com";
  in {
    # Set the formatter for `nix fmt`
    formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.alejandra;

    nixosConfigurations = {
      ${host_nmd} = let
        hostname = host_nmd;
        shortname = "nmd";
        fqdn = "${shortname}.${domain}";
      in
        nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = {
            inherit inputs outputs hostname fqdn domain;
          };
          modules = [
            ./systems/${hostname}
            ./modules
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
              nixpkgs.overlays = [
                (_: prev: {
                  unstable = import nixpkgs-unstable {
                    inherit (prev) system;
                  };

                  # TODO: Override pihole-exporter package with unstable since stable version is not yet compatible with pihole v6
                  prometheus-pihole-exporter = nixpkgs-unstable.legacyPackages."x86_64-linux".prometheus-pihole-exporter;
                })
              ];
            }
          ];
        };

      ${host_nsf} = let
        hostname = host_nsf;
        shortname = "nsf";
        fqdn = "${shortname}.${domain}";
      in
        nixpkgs-unstable.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = {
            inherit inputs outputs hostname fqdn domain;
          };
          modules = [
            ./systems/${hostname}
            ./modules
            ./common
            ./common/users
            ./common/sunshine
            ./common/alloy
            # Pin nixpkgs to the one used to build the system
            {nix.registry.nixpkgs.flake = nixpkgs-unstable;}
            home-manager.nixosModules.home-manager
            {
              home-manager = {
                useGlobalPkgs = true;
                useUserPackages = true;
                users.doot = import ./common/home/desktop.nix;
                extraSpecialArgs = {inherit inputs;};
              };
            }
            # Overlay nixpkgs-unstable. This host is based off of unstable, but the overlay should be available uniformly
            # TODO: Figure out a way to deduplicate this so it's the default for all host configs
            {
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
        shortname = "nsf";
        fqdn = "${shortname}.${domain}";
      in
        nixos-generators.nixosGenerate {
          system = "x86_64-linux";
          specialArgs = {
            inherit inputs outputs hostname fqdn domain;
          };
          modules = [
            ./systems/${hostname}
            ./modules
            ./common
            ./common/users
            ./common/sunshine
            ./common/alloy
            ./systems/nix-shitfucker/proxmox.nix
            # Overlay nixpkgs-unstable. This host is based off of unstable, but the overlay should be available uniformly
            # TODO: Figure out a way to deduplicate this so it's the default for all host configs
            {
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
