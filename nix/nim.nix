# Fetches the Nim source tree at the exact revision pinned in nimble.lock.
# The compiler binary is still pkgs.nim-2_2 (pre-built); this source is
# used to pin the stdlib to the same commit.
# Regenerate sha256 with:
#   nix shell nixpkgs#nix-prefetch-git --command \
#     nix-prefetch-git --url <url> --rev <vcsRevision> --fetch-submodules
{ pkgs }:
let
  lock = builtins.fromJSON (builtins.readFile ../nimble.lock);
  entry = lock.packages.nim;
in
pkgs.fetchgit {
  url = entry.url;
  rev = "v${entry.version}";
  sha256 = "1g4nxbwbc6h174gbpa3gcs47xwk6scbmiqlp0nq1ig3af8fcqcnj";
  fetchSubmodules = true;
}
