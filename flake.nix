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
  };

  outputs = { self, nixpkgs, rust-overlay }:
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

      # Prebuilt zerokit librln, fetched from the upstream GitHub release
      # rather than compiled from source. Compiling zerokit makes Nix download
      # its many crate dependencies from crates.io in one parallel burst, which
      # crates.io intermittently rejects with HTTP 403 (rate limiting from the
      # self-hosted runners' shared IP), breaking the nix build. The release
      # ships the exact `stateless` library this project links (see
      # scripts/build_rln.sh), so we use it directly — no Rust toolchain and
      # no crates.io access needed.
      #
      # Keep `rlnVersion` aligned with `LIBRLN_VERSION` in the Makefile and the
      # vendor/zerokit submodule. Each hash is the sha256 of the release tarball
      # for that platform; refresh all four when bumping the version.
      rlnVersion = "v2.0.2";
      rlnAssets = {
        "x86_64-linux"   = { triple = "x86_64-unknown-linux-gnu";  hash = "sha256-qbrUdaetYKFhjzxUP/QcwD3JHWJ8qk/tCMK3yXceIAk="; };
        "aarch64-linux"  = { triple = "aarch64-unknown-linux-gnu"; hash = "sha256-s4bWrmCcNTWHNyJwV73ilWNp58ZdAVG+TAgtWN1cTQs="; };
        "x86_64-darwin"  = { triple = "x86_64-apple-darwin";       hash = "sha256-ZaHP5CApN66FYY7jxwOmGcF9kJR78Fng3k1qE2W08Mk="; };
        "aarch64-darwin" = { triple = "aarch64-apple-darwin";      hash = "sha256-f2YppkPsKFdN00j+IY8fpvsebWTIb9lW/V1/vOTiVKU="; };
      };

      mkZerokitRln = system: pkgs:
        let
          asset = rlnAssets.${system} or
            (throw "zerokit ${rlnVersion} has no prebuilt rln asset for system '${system}'");
        in pkgs.stdenv.mkDerivation {
          pname = "librln";
          version = lib.removePrefix "v" rlnVersion;

          src = pkgs.fetchurl {
            url = "https://github.com/vacp2p/zerokit/releases/download/"
                + "${rlnVersion}/${asset.triple}-stateless-rln.tar.gz";
            hash = asset.hash;
          };

          # The tarball lays its files out under release/.
          sourceRoot = "release";
          dontConfigure = true;
          dontBuild = true;

          # The release .so was linked outside Nix, so it references system
          # libraries (libgcc_s, libstdc++, glibc) by bare name. autoPatchelfHook
          # points those at the Nix versions so the library loads correctly when
          # used by the Nix build. It does nothing for the static .a, and the
          # step is skipped on macOS (dylib paths are fixed in nix/default.nix).
          nativeBuildInputs =
            pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.autoPatchelfHook ];
          buildInputs =
            pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.stdenv.cc.cc.lib ];

          installPhase = ''
            runHook preInstall
            mkdir -p $out/lib
            cp librln.a     $out/lib/ 2>/dev/null || true
            cp librln.so    $out/lib/ 2>/dev/null || true
            cp librln.dylib $out/lib/ 2>/dev/null || true
            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description = "Prebuilt zerokit RLN library (stateless flavor)";
            homepage = "https://github.com/vacp2p/zerokit";
            license = with licenses; [ mit asl20 ];
            platforms = builtins.attrNames rlnAssets;
          };
        };
    in {
      packages = forAllSystems (system:
        let
          pkgs = pkgsFor system;

          zerokitRln = mkZerokitRln system pkgs;

          liblogosdelivery = pkgs.callPackage ./nix/default.nix {
            inherit pkgs;
            src = ./.;
            inherit zerokitRln;
            gitVersion = "v${nimbleVersion}-g${builtins.substring 0 6 shortRev}";
          };

          wakucanary = pkgs.callPackage ./nix/default.nix {
            inherit pkgs;
            src = ./.;
            targets = ["wakucanary"];
            inherit zerokitRln;
          };
        in {
          inherit liblogosdelivery wakucanary;
          # Expose the prebuilt librln so downstream consumers
          # (e.g. logos-delivery-module) bundle the exact same librln this
          # build links against.
          rln = zerokitRln;
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
