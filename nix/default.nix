{
  pkgs,
  src ? ../.,
  targets ? ["libwaku-android-arm64"],
  verbosity ? 1,
  useSystemNim ? true,
  quickAndDirty ? true,
  stableSystems ? [
    "x86_64-linux" "aarch64-linux"
  ],
  abidir ? null,
  zerokitRln,
}:

assert pkgs.lib.assertMsg ((src.submodules or true) == true)
  "Unable to build without submodules. Append '?submodules=1#' to the URI.";

let
  inherit (pkgs) stdenv lib writeScriptBin callPackage;

  androidManifest = "<manifest xmlns:android=\"http://schemas.android.com/apk/res/android\" package=\"com.example.mylibrary\" />";

  tools = pkgs.callPackage ./tools.nix {};
  version = tools.findKeyValue "^version = \"([a-f0-9.-]+)\"$" ../waku.nimble;
  revision = lib.substring 0 8 (src.rev or src.dirtyRev or "00000000");

in stdenv.mkDerivation {
  pname = "logos-messaging-nim";
  version = "${version}-${revision}";

  inherit src;

  # Runtime dependencies
  buildInputs = with pkgs; [
    openssl gmp zip
  ];

  # Dependencies that should only exist in the build environment.
  nativeBuildInputs = let
    # Fix for Nim compiler calling 'git rev-parse' and 'lsb_release'.
    fakeGit = writeScriptBin "git" "echo ${version}";
  in with pkgs; [
    cmake which zerokitRln nim-unwrapped-2_2 fakeGit
  ] ++ lib.optionals stdenv.isDarwin [
    pkgs.darwin.cctools gcc # Necessary for libbacktrace
  ];

  # Environment variables required for Android builds
  ANDROID_SDK_ROOT="${pkgs.androidPkgs.sdk}";
  ANDROID_NDK_HOME="${pkgs.androidPkgs.ndk}";
  NIMFLAGS = "-d:disableMarchNative -d:git_revision_override=${revision}";
  XDG_CACHE_HOME = "/tmp";

  makeFlags = targets ++ [
    "V=${toString verbosity}"
    "QUICK_AND_DIRTY_COMPILER=${if quickAndDirty then "1" else "0"}"
    "QUICK_AND_DIRTY_NIMBLE=${if quickAndDirty then "1" else "0"}"
    "USE_SYSTEM_NIM=${if useSystemNim then "1" else "0"}"
    "LIBRLN_FILE=${zerokitRln}/lib/librln.${if abidir != null then "so" else "a"}"
  ];

  configurePhase = ''
    patchShebangs . vendor/nimbus-build-system > /dev/null
    make nimbus-build-system-paths
    make nimbus-build-system-nimble-dir
  '';

  # For the Nim v2.2.4 built with NBS we added sat and zippy
  preBuild = lib.optionalString (!useSystemNim) ''
    pushd vendor/nimbus-build-system/vendor/Nim
    mkdir dist
    mkdir -p dist/nimble/vendor/sat
    mkdir -p dist/nimble/vendor/checksums
    mkdir -p dist/nimble/vendor/zippy

    cp -r ${callPackage ./nimble.nix {}}/.    dist/nimble
    cp -r ${callPackage ./checksums.nix {}}/. dist/checksums
    cp -r ${callPackage ./csources.nix {}}/.  csources_v2
    cp -r ${callPackage ./sat.nix {}}/.       dist/nimble/vendor/sat
    cp -r ${callPackage ./checksums.nix {}}/. dist/nimble/vendor/checksums
    cp -r ${callPackage ./zippy.nix {}}/.     dist/nimble/vendor/zippy
    chmod 777 -R dist/nimble csources_v2
    popd
  '';

  installPhase = if abidir != null then ''
    mkdir -p $out/jni
    cp -r ./build/android/${abidir}/* $out/jni/
    echo '${androidManifest}' > $out/jni/AndroidManifest.xml
    cd $out && zip -r libwaku.aar *
  '' else ''
    mkdir -p $out/bin $out/include

    # Copy library files from build directory (created by Make during buildPhase)
    # Note: build/ is in the source tree, not result/ (which is a post-build symlink)
    if [ -d build ]; then
      cp build/lib*.{so,dylib,dll,a} $out/bin/ 2>/dev/null || true
    fi

    # Copy header files
    cp library/libwaku.h $out/include/ 2>/dev/null || true
    cp liblogosdelivery/liblogosdelivery.h $out/include/ 2>/dev/null || true
  '';

  meta = with pkgs.lib; {
    description = "NWaku derivation to build libwaku for mobile targets using Android NDK and Rust.";
    homepage = "https://github.com/status-im/nwaku";
    license = licenses.mit;
    platforms = stableSystems;
  };
}
