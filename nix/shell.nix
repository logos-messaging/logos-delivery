{ pkgs  }:

pkgs.mkShell {
  inputsFrom = [
    pkgs.androidShell
  ] ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
    pkgs.libiconv
    pkgs.darwin.apple_sdk.frameworks.Security
  ];

  buildInputs = with pkgs; [
    git
    cargo
    rustup
    rustc
    cmake
    nim-2_2
    nimble
  ];
}
