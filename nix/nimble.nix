# Fetches Nimble at the exact revision pinned in nimble.lock.
# Regenerate sha256 with:
#   nix shell nixpkgs#nix-prefetch-git --command \
#     nix-prefetch-git --url <url> --rev <vcsRevision> --fetch-submodules
{ pkgs }:
let
  lock = builtins.fromJSON (builtins.readFile ../nimble.lock);
  entry = lock.packages.nimble;
in
pkgs.fetchgit {
  url = entry.url;
  rev = "v${entry.version}";
  sha256 = "18cwsjwcgjmnm42kr310hfbw06lym3vaj641i4pla6r8w22xqpqd";
  fetchSubmodules = true;
}
