{ pkgs  }:

let
  nimble = pkgs.nimble.overrideAttrs (_: {
    version = "0.26.0";
    src = pkgs.fetchFromGitHub {
      owner  = "nim-lang";
      repo   = "nimble";
      rev    = "v0.26.0";
      sha256 = "sha256-kF7Lx1u0Rc8P3XkcIgeDApcxGVcz4fqRD0f8u9ACGtE=";
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
  ]) ++ [ nimble ]; # nimble pinned to 0.26.0 via let binding above
}
