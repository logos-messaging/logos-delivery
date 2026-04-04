# Fetches the Nim source tree at the exact revision declared in waku.nimble.
# The compiler binary is still pkgs.nim-2_2 (pre-built); this source is
# used to pin the stdlib to the same commit.
# Regenerate sha256 with:
#   nix shell nixpkgs#nix-prefetch-git --command \
#     nix-prefetch-git --url https://github.com/nim-lang/Nim.git --rev v<version> --fetch-submodules
{ pkgs }:
let
  lines       = pkgs.lib.splitString "\n" (builtins.readFile ../waku.nimble);
  versionLine = builtins.head (builtins.filter
    (l: builtins.match "^requires \"nim ==.*" l != null) lines);
  version     = builtins.head (builtins.match ".*([0-9]+\\.[0-9]+\\.[0-9]+).*" versionLine);
in
pkgs.fetchgit {
  url = "https://github.com/nim-lang/Nim.git";
  rev = "v${version}";
  sha256 = "1g4nxbwbc6h174gbpa3gcs47xwk6scbmiqlp0nq1ig3af8fcqcnj";
  fetchSubmodules = true;
}
