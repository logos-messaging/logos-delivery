{
  description = "Logos Messaging Nim build flake";

  nixConfig = {
    extra-substituters = [ "https://nix-cache.status.im/" ];
    extra-trusted-public-keys = [ "nix-cache.status.im-1:x/93lOfLU+duPplwMSBR+OlY4+mo+dCN7n0mr4oPwgY=" ];
  };

  inputs = {
    # We are pinning the commit because ultimately we want to use same commit across different projects.
    # A commit from nixpkgs 24.11 release : https://github.com/NixOS/nixpkgs/tree/release-24.11
    nixpkgs.url = "github:NixOS/nixpkgs/0ef228213045d2cdb5a169a95d63ded38670b293";
    # WARNING: Remember to update commit and use 'nix flake update' to update flake.lock.
    zerokit = {
      url = "git+https://github.com/vacp2p/zerokit?rev=3160d9504d07791f2fc9b610948a6cf9a58ed488";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, zerokit }:
    let
      stableSystems = [
        "x86_64-linux" "aarch64-linux"
        "x86_64-darwin" "aarch64-darwin"
        "x86_64-windows" "i686-linux"
        "i686-windows"
      ];

      forAllSystems = f: nixpkgs.lib.genAttrs stableSystems (system: f system);

      pkgsFor = forAllSystems (
        system: import nixpkgs {
          inherit system;
          config = {
            android_sdk.accept_license = true;
            allowUnfree = true;
          };
          overlays =  [
            (final: prev: {
              androidEnvCustom = prev.callPackage ./nix/pkgs/android-sdk { };
              androidPkgs = final.androidEnvCustom.pkgs;
              androidShell = final.androidEnvCustom.shell;
            })
          ];
        }
      );

    in rec {
      packages = forAllSystems (system: let
        pkgs = pkgsFor.${system};
      in rec {
        libwaku-android-arm64 = pkgs.callPackage ./nix/default.nix {
          inherit stableSystems;
          src = self;
          targets = ["libwaku-android-arm64"];
          abidir = "arm64-v8a";
          zerokitRln = zerokit.packages.${system}.rln-android-arm64;
        };

        libwaku = pkgs.callPackage ./nix/default.nix {
          inherit stableSystems;
          src = self;
          targets = ["libwaku"];
          zerokitRln = zerokit.packages.${system}.rln;
        };

        wakucanary = pkgs.callPackage ./nix/default.nix {
          inherit stableSystems;
          src = self;
          targets = ["wakucanary"];
          zerokitRln = zerokit.packages.${system}.rln;
        };

        default = libwaku;
      });

      devShells = forAllSystems (system: {
        default = pkgsFor.${system}.callPackage ./nix/shell.nix {};
      });
    };
}
