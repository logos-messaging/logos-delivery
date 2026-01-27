{
  pkgs ? import <nixpkgs> { },
}:
let
  optionalDarwinDeps = pkgs.lib.optionals pkgs.stdenv.isDarwin [
    pkgs.libiconv
    pkgs.darwin.apple_sdk.frameworks.Security
  ];
in
pkgs.mkShell {
  inputsFrom = [
    pkgs.androidShell
  ] ++ optionalDarwinDeps;

  buildInputs = with pkgs; [
    git
    cargo
    rustup
    rustc
    cmake
    nim-unwrapped-2_0
  ];

}
