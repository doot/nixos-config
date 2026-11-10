{
  pkgs,
  src,
}:
pkgs.stdenvNoCC.mkDerivation {
  pname = "hermes-job-search";
  version = src.shortRev;
  inherit src;
  patches = [./job-search.patch];
  patchFlags = ["-p1" "--fuzz=0"];
  dontConfigure = true;
  dontBuild = true;
  installPhase = ''
    mkdir -p "$out/job-search/references"
    cp skills/job-search/SKILL.md "$out/job-search/"
    cp -r skills/job-search/assets skills/job-search/scripts "$out/job-search/"
    for reference in browser-setup data-directory prerequisites fit-scoring priority-hierarchy; do
      cp "shared/references/$reference.md" "$out/job-search/references/"
    done
  '';
}
