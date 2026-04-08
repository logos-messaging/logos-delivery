# Fetches Nimble at the exact revision declared in waku.nimble.
# Regenerate hash with:
#   nix store prefetch-file --hash-type sha256 --unpack \
#     https://github.com/nim-lang/nimble/archive/v<version>.tar.gz
# or set hash = "" and let Nix report the correct value.
{ pkgs }:
let
  lines       = pkgs.lib.splitString "\n" (builtins.readFile ../waku.nimble);
  versionLine = builtins.head (builtins.filter
    (l: builtins.match "^const NimbleVersion.*" l != null) lines);
  version     = builtins.head (builtins.match ".*\"([0-9]+\\.[0-9]+\\.[0-9]+)\".*" versionLine);
in
pkgs.fetchgit {
  url  = "https://github.com/nim-lang/nimble";
  rev  = "v${version}";
  hash = "sha256-wgzFhModFkwB8st8F5vSkua7dITGGC2cjoDvgkRVZMs=";
}
