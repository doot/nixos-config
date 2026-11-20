# The Hermes package, with local patches applied to its Python source.
#
# The package does not expose a patch hook, but takes uv2nix as an argument and builds
# its Python package from the overlay uv2nix's mkPyprojectOverlay returns, so
# the patches are added there. When there are no patches this is just the stock package
# and can use the upstream binary cache.
{
  lib,
  hermes-agent,
  system,
  patches ? [],
}: let
  stock = hermes-agent.packages.${system}.minimal;
  uv2nix = hermes-agent.inputs.uv2nix;

  # The package also loads its pm workspace through uv2nix; only the workspace
  # that defines hermes-agent is patched.
  addPatches = _final: prev:
    lib.optionalAttrs (prev ? hermes-agent) {
      hermes-agent = prev.hermes-agent.overrideAttrs (old: {
        patches = (old.patches or []) ++ patches;
      });
    };
in
  if patches == []
  then stock
  else
    stock.override {
      uv2nix = lib.recursiveUpdate uv2nix {
        lib.workspace.loadWorkspace = args: let
          workspace = uv2nix.lib.workspace.loadWorkspace args;
        in
          workspace
          // {
            mkPyprojectOverlay = overlayArgs:
              lib.composeExtensions (workspace.mkPyprojectOverlay overlayArgs) addPatches;
          };
      };
    }
