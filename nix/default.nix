{ pkgs, src, zerokitRln }:

let
  deps      = import ./deps.nix    { inherit pkgs; };

  # nat_traversal is excluded from the static pathArgs; it is handled
  # separately in buildPhase (its bundled C libs must be compiled first).
  otherDeps = builtins.removeAttrs deps [ "nat_traversal" ];

  # Some packages (e.g. regex, unicodedb) put their .nim files under src/
  # while others use the repo root. Pass both so the compiler finds either layout.
  pathArgs =
    builtins.concatStringsSep " "
      (builtins.concatMap (p: [ "--path:${p}" "--path:${p}/src" ])
        (builtins.attrValues otherDeps));

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
    gnumake
    which
  ] ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [ pkgs.darwin.cctools ];

  buildInputs = [ zerokitRln ];

  buildPhase = ''
    export HOME=$TMPDIR
    export XDG_CACHE_HOME=$TMPDIR/.cache
    export NIMBLE_DIR=$TMPDIR/.nimble
    export NIMCACHE=$TMPDIR/nimcache

    mkdir -p build $NIMCACHE

    # nat_traversal bundles C sub-libraries that must be compiled before linking.
    # Copy the fetchgit store path to a writable tmpdir, build, then pass to nim.
    NAT_TRAV=$TMPDIR/nat_traversal
    cp -r ${deps.nat_traversal} $NAT_TRAV
    chmod -R +w $NAT_TRAV

    make -C $NAT_TRAV/vendor/miniupnp/miniupnpc \
      CFLAGS="-Os -fPIC" build/libminiupnpc.a

    make -C $NAT_TRAV/vendor/libnatpmp-upstream \
      CFLAGS="-Wall -Os -fPIC -DENABLE_STRNATPMPERR -DNATPMP_MAX_RETRIES=4" libnatpmp.a

    echo "== Building liblogosdelivery (dynamic) =="
    nim c \
      --noNimblePath \
      ${pathArgs} \
      --path:$NAT_TRAV \
      --path:$NAT_TRAV/src \
      --passL:"-L${zerokitRln}/lib -lrln" \
      --define:disable_libbacktrace \
      --out:build/liblogosdelivery.${libExt} \
      --app:lib \
      --threads:on \
      --opt:size \
      --noMain \
      --mm:refc \
      --header \
      --nimMainPrefix:liblogosdelivery \
      --nimcache:$NIMCACHE \
      liblogosdelivery/liblogosdelivery.nim

    echo "== Building liblogosdelivery (static) =="
    nim c \
      --noNimblePath \
      ${pathArgs} \
      --path:$NAT_TRAV \
      --path:$NAT_TRAV/src \
      --passL:"-L${zerokitRln}/lib -lrln" \
      --define:disable_libbacktrace \
      --out:build/liblogosdelivery.a \
      --app:staticlib \
      --threads:on \
      --opt:size \
      --noMain \
      --mm:refc \
      --nimMainPrefix:liblogosdelivery \
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
