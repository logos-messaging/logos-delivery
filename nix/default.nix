{ pkgs, src, zerokitRln }:

let
  deps    = import ./deps.nix    { inherit pkgs; };
  nimSrc  = pkgs.callPackage ./nim.nix    {};
  nimbleSrc = pkgs.callPackage ./nimble.nix {};

  pathArgs =
    builtins.concatStringsSep " "
      (map (p: "--path:${p}") (builtins.attrValues deps));

  libExt =
    if pkgs.stdenv.hostPlatform.isWindows then "dll"
    else if pkgs.stdenv.hostPlatform.isDarwin then "dylib"
    else "so";
in
pkgs.stdenv.mkDerivation {
  pname = "liblogosdelivery";
  version = "dev";

  inherit src;

  nativeBuildInputs = with pkgs; [
    nim-2_2
    git
  ];

  buildInputs = [ zerokitRln ];

  buildPhase = ''
    export HOME=$TMPDIR
    export XDG_CACHE_HOME=$TMPDIR/.cache
    export NIMBLE_DIR=$TMPDIR/.nimble
    export NIMCACHE=$TMPDIR/nimcache

    mkdir -p build $NIMCACHE

    echo "== Building liblogosdelivery (dynamic) =="
    nim c \
      --noNimblePath \
      ${pathArgs} \
      --lib:${nimSrc}/lib \
      --nimblePath:${nimbleSrc} \
      --passL:"-L${zerokitRln}/lib -lrln" \
      --out:build/liblogosdelivery.${libExt} \
      --app:lib \
      --threads:on \
      --opt:size \
      --noMain \
      --mm:refc \
      --header \
      --nimcache:$NIMCACHE \
      liblogosdelivery/liblogosdelivery.nim

    echo "== Building liblogosdelivery (static) =="
    nim c \
      --noNimblePath \
      ${pathArgs} \
      --lib:${nimSrc}/lib \
      --nimblePath:${nimbleSrc} \
      --passL:"-L${zerokitRln}/lib -lrln" \
      --out:build/liblogosdelivery.a \
      --app:staticlib \
      --threads:on \
      --opt:size \
      --noMain \
      --mm:refc \
      --nimcache:$NIMCACHE \
      liblogosdelivery/liblogosdelivery.nim
  '';

  installPhase = ''
    mkdir -p $out/lib $out/include
    cp build/liblogosdelivery.${libExt} $out/lib/ 2>/dev/null || true
    cp build/liblogosdelivery.a         $out/lib/ 2>/dev/null || true
    cp liblogosdelivery/liblogosdelivery.h $out/include/ 2>/dev/null || true
  '';
}
