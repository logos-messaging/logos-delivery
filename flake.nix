{
  description = "logos-delivery nim build flake";

  nixConfig = {
    extra-substituters = [ "https://nix-cache.status.im/" ];
    extra-trusted-public-keys = [
      "nix-cache.status.im-1:x/93lOfLU+duPplwMSBR+OlY4+mo+dCN7n0mr4oPwgY="
    ];
  };

  inputs = {
    # Pinning the commit to use same commit across different projects.
    # A commit from nixpkgs 25.11 release: https://github.com/NixOS/nixpkgs/tree/release-25.11
    nixpkgs.url = "github:NixOS/nixpkgs?rev=23d72dabcb3b12469f57b37170fcbc1789bd7457";

    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # External flake input: Zerokit pinned to a specific commit.
    # Update the rev here when a new zerokit version is needed.
    zerokit = {
      url = "github:vacp2p/zerokit/53b18098e6d5d046e3eb1ac338a8f4f651432477";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, rust-overlay, zerokit }:
    let
      systems = [
        "x86_64-linux" "aarch64-linux"
        "x86_64-darwin" "aarch64-darwin"
        "x86_64-windows"
      ];

      forAllSystems = nixpkgs.lib.genAttrs systems;

      pkgsFor = system: import nixpkgs {
        inherit system;
        overlays = [ (import rust-overlay) ];
      };
    in {
      packages = forAllSystems (system:
        let
          pkgs = pkgsFor system;
          mkPkg = zerokitRln: import ./nix/default.nix {
            inherit pkgs zerokitRln;
            src = ./.;
          };
        in rec {
          liblogosdelivery = mkPkg zerokit.packages.${system}.rln;
          default          = liblogosdelivery;
        }
      );

      devShells = forAllSystems (system:
        let
          pkgs = pkgsFor system;
        in {
          default = pkgs.mkShell {
            nativeBuildInputs = with pkgs; [
              nim-2_2
              nimble
            ];
          };
        }
      );
    };
}
