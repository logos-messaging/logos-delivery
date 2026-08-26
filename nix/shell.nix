{ pkgs  }:

let
  nimble = pkgs.nimble.overrideAttrs (_: {
    version = "0.24.1";
    src = pkgs.fetchFromGitHub {
      owner  = "nim-lang";
      repo   = "nimble";
      rev    = "v0.24.1";
      sha256 = "sha256-A3TR0LNV7hvbMWBClLOxJB2fF4ayM25fm1bBMISHPpE=";
    };
  });
in

pkgs.mkShell {
  inputsFrom = [
    pkgs.androidShell
  ] ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
    pkgs.libiconv
    pkgs.darwin.apple_sdk.frameworks.Security
  ];

  buildInputs = (with pkgs; [
    git
    cargo
    rustup
    rustc
    cmake
    nim-2_2
  ]) ++ [ nimble ]; # nimble pinned to 0.24.1 via let binding above
}
