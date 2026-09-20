{
  description = "logos-delivery nim build flake";

  nixConfig = {
    extra-substituters = [ "https://cache.nix.logos.co/public" ];
    extra-trusted-public-keys = [
      "public:l4HrXgL4nw246+LBh2SOJyhz64BoGegOYLheT/iIAPU="
    ];
  };

  inputs = {
    # Pinning the commit to use same commit across different projects.
    # A commit from nixpkgs 25.11 release: https://github.com/NixOS/nixpkgs/tree/release-25.11
    # Includes the fetchCargoVendor crates.io CDN fix (nixpkgs 0fb82de3).
    nixpkgs.url = "github:NixOS/nixpkgs?rev=535f3e6942cb1cead3929c604320d3db54b542b9";

    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Zerokit v2.0.2 plus its MinGW rln package (vacp2p/zerokit#439's merge).
    # Keep rev in sync with the vendor/zerokit submodule.
    zerokit = {
      url = "github:vacp2p/zerokit/ea80f39be3e7944e4537b5f4726a7c4aabfe0ab5";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, rust-overlay, zerokit }:
    let
      systems = [
        "x86_64-linux" "aarch64-linux"
        "x86_64-darwin" "aarch64-darwin"
      ];

      forAllSystems = nixpkgs.lib.genAttrs systems;

      lib = nixpkgs.lib;

      # Single source of truth for the semver: the `version` field of
      # logos_delivery.nimble. Kept in sync with git tags by the version-check CI.
      nimbleVersion =
        let line = lib.findFirst (l: lib.hasPrefix "version = " l)
                     "version = \"unknown\""
                     (lib.splitString "\n" (builtins.readFile ./logos_delivery.nimble));
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

      # One host platform's packages.
      packagesFor = { pkgs, zerokitRln, libpqPackage ? null }:
        let
          liblogosdelivery = pkgs.callPackage ./nix/default.nix {
            inherit pkgs;
            src = ./.;
            inherit zerokitRln;
            gitVersion = "v${nimbleVersion}-g${builtins.substring 0 6 shortRev}";
          };

          # `-d:postgres` binds libpq before main(), and on Windows that must be
          # satisfied from the exe's own directory -- so only Windows apps carry it.
          wakucanary = pkgs.callPackage ./nix/default.nix {
            inherit pkgs;
            src = ./.;
            targets = ["wakucanary"];
            inherit zerokitRln libpqPackage;
          };

          logosdeliverynode = pkgs.callPackage ./nix/default.nix {
            inherit pkgs;
            src = ./.;
            targets = ["logosdeliverynode"];
            inherit zerokitRln libpqPackage;
            gitVersion = "v${nimbleVersion}-g${builtins.substring 0 6 shortRev}";
          };
        in {
          inherit liblogosdelivery wakucanary logosdeliverynode;
          # Expose librln so downstream consumers link the exact same build.
          rln = zerokitRln;
        };

      # The Windows build is a MinGW cross build, published the way zerokit
      # publishes its own (vacp2p/zerokit#438): packages.<build>.<name>-windows-x86_64.
      windowsPkgsFor = system: import nixpkgs {
        localSystem = system;
        crossSystem = {
          config = "x86_64-w64-mingw32";
          # msvcrt, matching MSYS2's MINGW64 environment -- so a DLL built
          # here and one built by the MSYS2 CI job share a C runtime.
          libc = "msvcrt";
        };
        # nimbleOverlay is deliberately absent: nimble is a devShell tool and
        # a mingw-hosted nimble neither builds nor is ever run.
        overlays = [ (import rust-overlay) ];
      };

      # libpq is no link-time dependency (db_connector dlopens it); it is its own
      # package so consumers can bundle it beside the image, where Windows looks.
      windowsLibpq = pkgs:
        (pkgs.libpq.override {
          # postgres 18 links libcurl for OAuth; curl cross to mingw drags in
          # ngtcp2 -> nghttp3, whose EXAMPLES include <arpa/inet.h> and fail.
          curlSupport = false;
        }).overrideAttrs (o: {
          # makeWrapper wants a HOST-platform bash (mingw bash does not build)
          # and nothing in libpq actually calls wrapProgram.
          nativeBuildInputs = builtins.filter
            (d: !(builtins.isAttrs d && (d.name or "") == "make-shell-wrapper-hook"))
            o.nativeBuildInputs;
          # pg_pthread.h includes <pthread.h> unconditionally, and mingw-w64 here
          # is built against mcfgthread, so winpthreads must be supplied.
          buildInputs = o.buildInputs ++ [ pkgs.windows.pthreads ];
          # objcopy --only-keep-debug on a PE is not the ELF split this assumes.
          separateDebugInfo = false;
          meta = o.meta // { platforms = o.meta.platforms ++ lib.platforms.windows; };
        });

      windowsPackagesFor = system:
        let
          pkgs = windowsPkgsFor system;
          libpq = windowsLibpq pkgs;
          windowsPackages = packagesFor {
            inherit pkgs;
            zerokitRln = import ./nix/zerokit.nix { inherit zerokit system; windows = true; };
            libpqPackage = libpq;
          } // { inherit libpq; };
        in
        lib.mapAttrs' (name: lib.nameValuePair "${name}-windows-x86_64") windowsPackages;
    in {
      packages = forAllSystems (system:
        let
          pkgs = pkgsFor system;
          nativePackages = packagesFor {
            inherit pkgs;
            zerokitRln = import ./nix/zerokit.nix { inherit zerokit system; };
          };
        in
        nativePackages // {
          # Runtime-only; see windowsLibpq.
          libpq = pkgs.libpq;
          default = nativePackages.liblogosdelivery;
        }
        # zerokit builds its MinGW rln only on x86_64-linux, so the Windows
        # packages live there too.
        // lib.optionalAttrs (system == "x86_64-linux") (windowsPackagesFor system)
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
