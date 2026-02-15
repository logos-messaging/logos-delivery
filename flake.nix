{
  description = "Logos-message-delivery build flake";

  nixConfig = {
    extra-substituters = [ "https://nix-cache.status.im/" ];
    extra-trusted-public-keys = [ "nix-cache.status.im-1:x/93lOfLU+duPplwMSBR+OlY4+mo+dCN7n0mr4oPwgY=" ];
  };

  inputs = {
    # Pinned nixpkgs commit
    nixpkgs.url = "github:NixOS/nixpkgs?rev=f44bd8ca21e026135061a0a57dcf3d0775b67a49";

    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # External flake input: Zerokit pinned to a specific commit
    zerokit = {
      url = "github:vacp2p/zerokit/v0.9.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, rust-overlay, zerokit }:
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
          overlays = [
            rust-overlay.overlays.default
            (final: prev: {
              androidEnvCustom = prev.callPackage ./nix/pkgs/android-sdk { };
              androidPkgs = final.androidEnvCustom.pkgs;
              androidShell = final.androidEnvCustom.shell;
            })
          ];
        }
      );

    in rec {
      packages = forAllSystems (system:
        let pkgs = pkgsFor.${system};

        in rec {
          # Consumer packages (src = self)
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

          liblogosdelivery = pkgs.callPackage ./nix/default.nix {
            inherit stableSystems;
            src = self;
            targets = ["liblogosdelivery"];
            zerokitRln = zerokit.packages.${system}.rln;
          };

          default = libwaku;
        }
      );

      devShells = forAllSystems (system: {
        default = pkgsFor.${system}.callPackage ./nix/shell.nix {};
      });
    };
}
