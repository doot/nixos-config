{host}: let
  inherit (host) pkgs config;
  inherit (config.environment.variables) NVIM_TREESITTER_GRAMMARS;
  closure = pkgs.closureInfo {rootPaths = [NVIM_TREESITTER_GRAMMARS];};
in
  pkgs.runCommand "neovim-treesitter-test" {inherit NVIM_TREESITTER_GRAMMARS;} ''
    while IFS= read -r path; do
      for tool in cc gcc clang tree-sitter; do
        if [[ -x "$path/bin/$tool" ]]; then
          echo "Unexpected grammar runtime dependency: $path/bin/$tool" >&2
          exit 1
        fi
      done
    done < ${closure}/store-paths

    HOME="$TMPDIR" PATH= NVIM_APPNAME=lazyvim \
      ${config.programs.neovim.package}/bin/nvim --headless -u NONE -i NONE -l ${./neovim-treesitter.lua}
    touch "$out"
  ''
