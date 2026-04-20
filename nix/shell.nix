{ pkgs  }:

let
  nimble = pkgs.nimble.overrideAttrs (_: {
    version = "0.22.3";
    src = pkgs.fetchFromGitHub {
      owner  = "nim-lang";
      repo   = "nimble";
      rev    = "v0.22.3";
      sha256 = "sha256-f7DYpRGVUeSi6basK1lfu5AxZpMFOSJ3oYsy+urYErg=";
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
  ]) ++ [ nimble ]; # nimble pinned to 0.22.3 via let binding above
}
