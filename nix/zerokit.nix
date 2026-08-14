# zerokit rln built from source; overrides the stale v2.0.2 vendor cargoHash.
#
# x86_64-windows is a pseudo-system meaning "cross to x86_64-w64-mingw32", and
# zerokit's own flake cannot serve it: its nix/default.nix takes the toolchain
# from pkgsCross.<target>.rust-bin (rust-overlay), which for a MinGW target
# evaluates nixpkgs all-packages.nix:5374 -- a threadsCross default reading
# targetPackages.threads.package, an attribute only the MinGW branch touches
# and that the cross set does not define.
#
# The Windows variant therefore builds here with a BUILD-PLATFORM rust-overlay
# toolchain that has the windows-gnu target added, cross-linked through the
# mingw cc. Note that pkgsCross.mingwW64.rustPlatform -- the other obvious fix --
# works but bootstraps a whole rustc from source (~1h, not in any binary cache),
# because a cross rustc with this target is not a Hydra job.
{ pkgs, zerokit, system }:

let
  # zerokit v2.0.2 committed a cargoHash that no longer matches the crates.io
  # CDN contents; correct it in the inner vendor staging FOD.
  fixVendorHash =
    drv:
    drv.overrideAttrs (old: {
      cargoDeps = old.cargoDeps.overrideAttrs (oldCargoDeps: {
        vendorStaging = oldCargoDeps.vendorStaging.overrideAttrs (_: {
          outputHash = "sha256-PNwEdZLgGQPqQDrEK2hsQtSybVfBbD6xn4K47fPFJUU=";
        });
      });
    });

  # `pkgs` is already the cross set when system == x86_64-windows, so its
  # stdenv.cc is the mingw wrapper and hostPlatform.rust.rustcTarget is
  # x86_64-pc-windows-gnu.
  crossCC = pkgs.stdenv.cc;
  rustTarget = pkgs.stdenv.hostPlatform.rust.rustcTarget;
  # Cargo reads per-target settings from CARGO_TARGET_<TRIPLE>_*, upper-cased
  # with dashes turned into underscores.
  rustTargetUnderscored = builtins.replaceStrings [ "-" ] [ "_" ] rustTarget;
  targetEnvPrefix = "CARGO_TARGET_" + (pkgs.lib.toUpper rustTargetUnderscored);

  toolchain = pkgs.buildPackages.rust-bin.stable.latest.default.override {
    targets = [ rustTarget ];
  };
  rustPlatform = pkgs.buildPackages.makeRustPlatform {
    cargo = toolchain;
    rustc = toolchain;
  };

  rlnCross = rustPlatform.buildRustPackage {
    pname = "rln";
    version = "2.0.2";
    src = zerokit;

    cargoHash = "sha256-3wFnSJYUSQ01tQLe4nZGUZdoU1A9vsl9dpJU3vPeiHo=";

    # All build-platform tools: cbindgen runs on the builder, and the mingw cc
    # is what cargo shells out to for linking.
    nativeBuildInputs = [ pkgs.buildPackages.rust-cbindgen crossCC ];

    env = {
      "${targetEnvPrefix}_LINKER" = "${crossCC}/bin/${crossCC.targetPrefix}cc";

      # zstd-sys (and any other cc-rs build script) compiles bundled C. cc-rs
      # keys its toolchain off CC_<triple>/AR_<triple> with dashes replaced by
      # underscores; without these it silently builds the C for the BUILD host
      # and the link then fails on undefined ZSTD_* references.
      "CC_${rustTargetUnderscored}" = "${crossCC}/bin/${crossCC.targetPrefix}cc";
      "CXX_${rustTargetUnderscored}" = "${crossCC}/bin/${crossCC.targetPrefix}c++";
      "AR_${rustTargetUnderscored}" =
        "${crossCC.bintools}/bin/${crossCC.targetPrefix}ar";
      # Rust's windows-gnu std links `-l:libpthread.a`, but nixpkgs builds
      # mingw-w64 against mcfgthread, which ships no pthread library at all.
      # buildInputs would not help: this derivation runs in the BUILD-platform
      # stdenv, so its NIX_LDFLAGS never reach the mingw wrapper.
      "${targetEnvPrefix}_RUSTFLAGS" = "-L native=${pkgs.windows.pthreads}/lib";
    };

    buildPhase = ''
      runHook preBuild
      export CARGO_HOME=$TMPDIR/cargo
      cargo build --lib --release \
        --target=${rustTarget} \
        --manifest-path rln/Cargo.toml
      runHook postBuild
    '';

    # A cargo cdylib on Windows is `rln.dll` -- no `lib` prefix -- so zerokit's
    # own `find -name 'librln.*'` matches nothing and would install an EMPTY
    # $out/lib without failing. Fail loudly instead.
    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib $out/bin $out/include
      # Windows splits a shared library: the .dll is a RUNTIME artifact and goes
      # in bin/ (CMake's RUNTIME destination, and the only directory nixpkgs'
      # win-dll-link hook stages dependencies into); the import library
      # librln.dll.a and the static librln.a stay in lib/ as link-time inputs.
      find target -type f -name 'rln.dll' -not -path '*/deps/*' \
        -exec cp -v {} $out/bin/ \;
      find target -type f -name 'librln.*' -not -path '*/deps/*' \
        -exec cp -v {} $out/lib/ \;
      cbindgen ./rln -l c > $out/include/rln.h
      if [ -z "$(ls -A $out/lib)" ] && [ -z "$(ls -A $out/bin)" ]; then
        echo "error: no rln artifacts found under target/" >&2
        exit 1
      fi
      runHook postInstall
    '';

    doCheck = false;
    # The native stdenv's strip would be pointed at PE objects it does not own.
    dontStrip = true;
  };
in
fixVendorHash (
  if system != "x86_64-windows" then zerokit.packages.${system}.rln else rlnCross
)
