{
  pkgs,
  hermes-agent,
}: let
  inherit (pkgs) lib;
  inherit (hermes-agent.inputs) uv2nix;
  package = hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.default;
  identityHelper = pkgs.writeText "hermes-recovery-identity.py" (builtins.readFile ./hermes-recovery-identity.py);

  # Patch the wheel inside uv2nix, not the outer launcher derivation.
  recoveryOverlay = _final: prev: {
    hermes-agent = prev.hermes-agent.overrideAttrs (old: {
      patches = (old.patches or []) ++ [./hermes-recovery.patch];
      postPatch =
        (old.postPatch or "")
        + ''
          cp ${identityHelper} gateway/recovery_identity.py
          substituteInPlace gateway/recovery_identity.py \
            --replace-fail '@systemd_run@' '${pkgs.systemd}/bin/systemd-run' \
            --replace-fail '@python@' '${pkgs.python3}/bin/python3' \
            --replace-fail '@identity_helper@' '${identityHelper}'
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
          lib.composeExtensions (workspace.mkPyprojectOverlay overlayArgs) recoveryOverlay;
      };
  };
in
  (package.override {uv2nix = patchedUv2nix;}).overrideAttrs (old: {
    # Runs again after moduleCommon applies extraPythonPackages/dependency groups.
    postInstall =
      (old.postInstall or "")
      + ''
        HERMES_HOME="$TMPDIR/hermes-probe-test" \
          ${old.passthru.hermesVenv}/bin/python3 -I ${./hermes-package-test.py}
        HERMES_HOME="$TMPDIR/hermes-recovery-test" \
          ${old.passthru.hermesVenv}/bin/python3 -I ${./hermes-recovery-test.py} \
          --helper ${identityHelper} --helper-python ${pkgs.python3}/bin/python3
      '';
  })
