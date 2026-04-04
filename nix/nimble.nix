# Fetches Nimble at the exact revision declared in waku.nimble.
# Regenerate sha256 with:
#   nix shell nixpkgs#nix-prefetch-git --command \
#     nix-prefetch-git --url https://github.com/nim-lang/nimble --rev v<version> --fetch-submodules
{ pkgs }:
let
  lines       = pkgs.lib.splitString "\n" (builtins.readFile ../waku.nimble);
  versionLine = builtins.head (builtins.filter
    (l: builtins.match "^requires \"nimble ==.*" l != null) lines);
  version     = builtins.head (builtins.match ".*([0-9]+\\.[0-9]+\\.[0-9]+).*" versionLine);
in
pkgs.fetchgit {
  url = "https://github.com/nim-lang/nimble";
  rev = "v${version}";
  sha256 = "18cwsjwcgjmnm42kr310hfbw06lym3vaj641i4pla6r8w22xqpqd";
  fetchSubmodules = true;
}
