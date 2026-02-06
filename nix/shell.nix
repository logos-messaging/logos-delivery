{
  pkgs ? import <nixpkgs> { },
  nim ? null,
}:

pkgs.mkShell {
  inputsFrom = [
    pkgs.androidShell
  ];

  buildInputs = with pkgs; [
    git
    nim
    cargo
    rustup
    rustc
    cmake
  ] ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
    pkgs.libiconv
    pkgs.darwin.apple_sdk.frameworks.Security
  ];
}
