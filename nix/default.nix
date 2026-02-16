{
  pkgs,
  src ? ../.,
  targets ? ["libwaku-android-arm64"],
  verbosity ? 1,
  stableSystems ? [
    "x86_64-linux" "aarch64-linux"
  ],
  abidir ? null,
  zerokitRln,
}:

let
  inherit (pkgs) stdenv lib writeScriptBin callPackage;

  androidManifest = "<manifest xmlns:android=\"http://schemas.android.com/apk/res/android\" package=\"com.example.mylibrary\" />";

  tools = pkgs.callPackage ./tools.nix {};
  version = tools.findKeyValue "^version = \"([a-f0-9.-]+)\"$" ../waku.nimble;
  revision = lib.substring 0 8 (src.rev or src.dirtyRev or "00000000");
  copyLibwaku = lib.elem "libwaku" targets;
  copyLiblogosdelivery = lib.elem "liblogosdelivery" targets;
  copyWakunode2 = lib.elem "wakunode2" targets;
  hasKnownInstallTarget = copyLibwaku || copyLiblogosdelivery || copyWakunode2;

  nimbleDeps = callPackage ./deps.nix {
    inherit src version revision;
  };

in stdenv.mkDerivation {
  pname = "logos-delivery";
  inherit src;
  version = "${version}-${revision}";

  env = {
    ANDROID_SDK_ROOT="${pkgs.androidPkgs.sdk}";
    ANDROID_NDK_HOME="${pkgs.androidPkgs.ndk}";
    NIMFLAGS = "-d:disableMarchNative -d:git_revision_override=${revision}";
  };

  buildInputs = with pkgs; [
    openssl gmp zip bash nim nimble cacert
  ];

  nativeBuildInputs = let
    # Fix for Nim compiler calling 'git rev-parse' and 'lsb_release'.
    fakeGit = writeScriptBin "git" "echo ${version}";
  in with pkgs; [
    cmake which zerokitRln fakeGit nimbleDeps cargo nimble nim cacert
  ] ++ lib.optionals stdenv.isDarwin [
    pkgs.darwin.cctools gcc # Necessary for libbacktrace
  ];

  makeFlags = targets ++ [
    "V=${toString verbosity}"
    "LIBRLN_FILE=${zerokitRln}/lib/librln.${if abidir != null then "so" else "a"}"
    "POSTGRES=1"
  ];

  configurePhase = ''
    export HOME=$TMPDIR/myhome
    mkdir -p $HOME
    export NIMBLE_DIR=$NIX_BUILD_TOP/nimbledeps
    cp -r ${nimbleDeps}/nimbledeps $NIMBLE_DIR
    cp ${nimbleDeps}/nimble.paths ./
    chmod 775 -R $NIMBLE_DIR
    # Fix relative paths to absolute paths
    sed -i "s|./nimbledeps|$NIMBLE_DIR|g" nimble.paths

  '';

  installPhase = if abidir != null then ''
    mkdir -p $out/jni
    cp -r ./build/android/${abidir}/* $out/jni/
    echo '${androidManifest}' > $out/jni/AndroidManifest.xml
    cd $out && zip -r libwaku.aar *
  '' else ''
    mkdir -p $out/bin $out/include

    # Copy artifacts from build directory (created by Make during buildPhase)
    # Note: build/ is in the source tree, not result/ (which is a post-build symlink)
    if [ -d build ]; then
      ${lib.optionalString copyLibwaku ''
      cp build/libwaku.{so,dylib,dll,a,lib} $out/bin/ 2>/dev/null || true
      ''}

      ${lib.optionalString copyLiblogosdelivery ''
      cp build/liblogosdelivery.{so,dylib,dll,a,lib} $out/bin/ 2>/dev/null || true
      ''}

      ${lib.optionalString copyWakunode2 ''
      cp build/wakunode2 $out/bin/ 2>/dev/null || true
      ''}

      ${lib.optionalString (!hasKnownInstallTarget) ''
      cp build/lib*.{so,dylib,dll,a,lib} $out/bin/ 2>/dev/null || true
      ''}
    fi

    # Copy header files
    ${lib.optionalString copyLibwaku ''
    cp library/libwaku.h $out/include/ 2>/dev/null || true
    ''}

    ${lib.optionalString copyLiblogosdelivery ''
    cp liblogosdelivery/liblogosdelivery.h $out/include/ 2>/dev/null || true
    ''}

    ${lib.optionalString (!hasKnownInstallTarget) ''
    cp library/libwaku.h $out/include/ 2>/dev/null || true
    cp liblogosdelivery/liblogosdelivery.h $out/include/ 2>/dev/null || true
    ''}
  '';

  meta = with pkgs.lib; {
    description = "Logos-message-delivery derivation.";
    homepage = "https://github.com/logos-messaging/logos-messaging-nim";
    license = licenses.mit;
    platforms = stableSystems;
  };
}
