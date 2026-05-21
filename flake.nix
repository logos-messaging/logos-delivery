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
      # Pinned to v2.0.2 (5e64cb8822bee65eed6cf459f95ae72b80c6ba63) to match
      # the vendor/zerokit submodule. Keep these two in sync: the nix build
      # links librln from this input, the Makefile build from the submodule.
      url = "github:vacp2p/zerokit/5e64cb8822bee65eed6cf459f95ae72b80c6ba63";
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

      lib = nixpkgs.lib;

      # Single source of truth for the semver: the `version` field of
      # waku.nimble. Kept in sync with git tags by the version-check CI.
      nimbleVersion =
        let line = lib.findFirst (l: lib.hasPrefix "version = " l)
                     "version = \"unknown\""
                     (lib.splitString "\n" (builtins.readFile ./waku.nimble));
        in lib.removeSuffix "\"" (lib.removePrefix "version = \"" line);

      # A flake sandbox has no .git, so `git describe` is impossible; the
      # commit comes from the flake metadata instead.
      shortRev = self.shortRev or self.dirtyShortRev or "dirty";

      nimbleOverlay = final: prev: {
        nimble = prev.nimble.overrideAttrs (_: {
          version = "0.22.3";
          src = prev.fetchFromGitHub {
            owner = "nim-lang";
            repo  = "nimble";
            rev   = "v0.22.3";
            sha256 = "sha256-f7DYpRGVUeSi6basK1lfu5AxZpMFOSJ3oYsy+urYErg=";
          };
        });
      };

      pkgsFor = system: import nixpkgs {
        inherit system;
        overlays = [ (import rust-overlay) nimbleOverlay ];
      };
    in {
      packages = forAllSystems (system:
        let
          pkgs = pkgsFor system;

          # zerokit's nix/default.nix hardcodes a cargoHash that is stale for
          # our pinned nixpkgs on a cold runner (the status.im substituter is
          # untrusted here, so the cargo-vendor FOD is recomputed). v2.0.2 did
          # NOT fix this for consumers — its committed hash is the old v2.0.1
          # value while v2.0.2's Cargo.lock changed. Rebuild librln here from
          # the pinned zerokit source with the correct cargoHash. Keep the
          # version + cargoHash in sync with the zerokit input rev.
          rustToolchain = pkgs.rust-bin.stable.latest.default;
          zerokitRln = pkgs.rustPlatform.buildRustPackage {
            pname = "zerokit";
            version = "2.0.2";
            src = zerokit;
            cargo = rustToolchain;
            rustc = rustToolchain;
            cargoHash = "sha256-PNwEdZLgGQPqQDrEK2hsQtSybVfBbD6xn4K47fPFJUU=";
            nativeBuildInputs = [ pkgs.rust-cbindgen ];
            doCheck = false;
            buildPhase = ''
              export CARGO_HOME=$TMPDIR/cargo
              cargo build --lib --release --manifest-path rln/Cargo.toml
            '';
            installPhase = ''
              set -eu
              mkdir -p $out/lib $out/include
              find target -type f -name 'librln.*' -not -path '*/deps/*' \
                -exec cp -v '{}' "$out/lib/" \;
              cbindgen ./rln -l c > "$out/include/rln.h"
            '';
          };

          liblogosdelivery = pkgs.callPackage ./nix/default.nix {
            inherit pkgs;
            src = ./.;
            inherit zerokitRln;
            gitVersion = "v${nimbleVersion}-g${builtins.substring 0 6 shortRev}";
          };
        in {
          inherit liblogosdelivery;
          default = liblogosdelivery;
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
