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

    # The Logos Core module (library/logos_module): the builder that wraps the
    # module image in logos-core's plugin glue and bundles it.
    logos-module-builder.url = "github:logos-co/logos-module-builder/0.3.1";
    # The name is load-bearing: the builder resolves each optional_dependencies
    # entry of metadata.json as the input of that name and generates the
    # module's bindings from its LIDL.
    liblogos_rln_module.url = "git+https://github.com/logos-co/logos-rln-modules?ref=main&rev=65697028baffc072e1aeebaec7c7e35e7e12cab1&dir=logos-rln-module";
  };

  outputs = inputs@{ self, nixpkgs, rust-overlay, zerokit, logos-module-builder, ... }:
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
            inherit zerokitRln libpqPackage;
            gitVersion = "v${nimbleVersion}-g${builtins.substring 0 6 shortRev}";
          };

          # `-d:postgres` binds libpq before main(), so each Windows artifact
          # receives the cross-built runtime through libpqPackage.
          # The Logos Core module image (see library/logos_module).
          liblogosdelivery_module = pkgs.callPackage ./nix/default.nix {
            inherit pkgs;
            src = ./.;
            inherit zerokitRln libpqPackage;
            gitVersion = "v${nimbleVersion}-g${builtins.substring 0 6 shortRev}";
            moduleImage = true;
          };
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
          inherit liblogosdelivery liblogosdelivery_module wakucanary logosdeliverynode;
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

      windowsPackagesFor = system:
        let
          pkgs = windowsPkgsFor system;
          libpq = import ./nix/libpq.nix { inherit pkgs; };
          windowsPackages = packagesFor {
            inherit pkgs;
            zerokitRln = import ./nix/zerokit.nix { inherit zerokit system; windows = true; };
            libpqPackage = libpq;
          } // { inherit libpq; };
        in
        lib.mapAttrs' (name: lib.nameValuePair "${name}-windows-x86_64") windowsPackages;
      # The library's own packages, per system: what this flake publishes and
      # what the module below links.
      libraryPackages = forAllSystems (system:
        let
          pkgs = pkgsFor system;
          nativePackages = packagesFor {
            inherit pkgs;
            zerokitRln = import ./nix/zerokit.nix { inherit zerokit system; };
          };
        in
        nativePackages // {
          default = nativePackages.liblogosdelivery;
        }
        # zerokit builds its MinGW rln only on x86_64-linux, so the Windows
        # packages live there too.
        // lib.optionalAttrs (system == "x86_64-linux") (windowsPackagesFor system)
      );

      # The Logos Core module: library/logos_module wrapped in logos-core's
      # plugin glue. Its external libraries are this flake's own packages.
      module = logos-module-builder.lib.mkLogosModule {
        src = ./library/logos_module;
        configFile = ./library/logos_module/metadata.json;
        flakeInputs = inputs;
        externalLibInputs = {
          # The module image: liblogosdelivery plus the logos_module_* exports.
          logosdelivery_module = {
            input = { packages = libraryPackages; };
            packages.default = "liblogosdelivery_module";
          };
          # librln beside the plugin: the exact, cargoHash-corrected build the
          # library links.
          rln = {
            input = { packages = libraryPackages; };
            packages.default = "rln";
            systems.x86_64-windows = {
              system = "x86_64-linux";
              packages.default = "rln-windows-x86_64";
            };
          };
        };
        postInstall = ''
          # librln.dylib is copied out of zerokit's output, so everything it loads
          # by absolute store path is a dependency of zerokit and not of this
          # module. A module travels to an app inside an LGX archive, which nix
          # cannot scan for store paths, so nothing installs those alongside the
          # module and the plugin fails to dlopen wherever they do not already
          # exist. Bundle them next to librln and load them through @loader_path,
          # the way librln and libpq already travel with the module. Transitively:
          # the libiconv librln loads re-exports libcharset from the same path.
          pending="$out/lib/librln.dylib"
          while [ -n "$pending" ]; do
            next=""
            for macho in $pending; do
              [ -f "$macho" ] || continue
              chmod u+w "$macho"
              for dep in $(otool -l "$macho" | awk '
                $1 == "cmd" { load = ($2 ~ /^LC_(LOAD_DYLIB|LOAD_WEAK_DYLIB|REEXPORT_DYLIB)$/) }
                load && $1 == "name" && $2 ~ "^/nix/store/" { print $2 }
              '); do
                name=$(basename "$dep")
                if [ ! -f "$out/lib/$name" ]; then
                  echo "Bundling $dep as @loader_path/$name"
                  cp -L "$dep" "$out/lib/$name"
                  chmod u+w "$out/lib/$name"
                  install_name_tool -id "@loader_path/$name" "$out/lib/$name"
                  next="$next $out/lib/$name"
                fi
                install_name_tool -change "$dep" "@loader_path/$name" "$macho"
              done
            done
            pending="$next"
          done
        '';
      };

      # The RLN modules a node on an RLN-enabled preset loads before createNode,
      # from this flake's own locked inputs.
      rlnModule = inputs.liblogos_rln_module;
      lezRlnModule = rlnModule.inputs.liblogos_lez_rln_module;
    in {
      packages = forAllSystems (system:
        libraryPackages.${system}
        # The module's, under its name: the plugin, the bundle logoscore
        # installs (and its portable variant), the generated glue, the LIDL.
        // lib.filterAttrs (name: _: lib.hasPrefix "delivery_module-" name) module.packages.${system}
        // {
          delivery_module = module.packages.${system}.lib;
          "delivery_module-lgx" = module.packages.${system}.lgx;
          "delivery_module-lgx-portable" = module.packages.${system}."lgx-portable";
          "delivery_module-install" = module.packages.${system}.install;
          "liblogos_rln_module-lgx" = rlnModule.packages.${system}.lgx;
          "liblogos_lez_rln_module-lgx" = lezRlnModule.packages.${system}.lgx;
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
