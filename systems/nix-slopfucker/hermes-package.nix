{
  pkgs,
  hermes-agent,
}: let
  inherit (pkgs) lib;
  inherit (hermes-agent.inputs) uv2nix;
  package = hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.default;

  # Patch the wheel inside uv2nix, not the outer launcher derivation.
  probeOverlay = _final: prev: {
    hermes-agent = prev.hermes-agent.overrideAttrs (old: {
      postPatch =
        (old.postPatch or "")
        + ''
          substituteInPlace tools/process_registry.py \
            --replace-fail '_systemd_scope_argv(binary, probe_unit, "/bin/true")' \
            '_systemd_scope_argv(binary, probe_unit, "${pkgs.coreutils}/bin/true")'
        '';
    });
  };

  patchedUv2nix = lib.recursiveUpdate uv2nix {
    lib.workspace.loadWorkspace = args: let
      workspace = uv2nix.lib.workspace.loadWorkspace args;
    in
      workspace
      // {
        mkPyprojectOverlay = overlayArgs:
          lib.composeExtensions (workspace.mkPyprojectOverlay overlayArgs) probeOverlay;
      };
  };
in
  (package.override {uv2nix = patchedUv2nix;}).overrideAttrs (old: {
    # Runs again after moduleCommon applies extraPythonPackages/dependency groups.
    postInstall =
      (old.postInstall or "")
      + ''
        HERMES_HOME="$TMPDIR/hermes-probe-test" \
          ${old.passthru.hermesVenv}/bin/python3 -I ${./hermes-package-test.py} \
          ${pkgs.coreutils}/bin/true
      '';
  })
