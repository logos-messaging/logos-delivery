{ pkgs
, src
, zerokitRln
, enablePostgres       ? true
, enableNimDebugDlOpen ? true
, chroniclesLogLevel   ? null
}:

let
  deps = import ./deps.nix { inherit pkgs; };

  nimDefineArgs = pkgs.lib.concatStringsSep " \\\n      " (
       [ "--define:disable_libbacktrace" ]
    ++ pkgs.lib.optional enablePostgres       "--define:postgres"
    ++ pkgs.lib.optional enableNimDebugDlOpen "--define:nimDebugDlOpen"
    ++ pkgs.lib.optional (chroniclesLogLevel != null)
         "--define:chronicles_log_level=${toString chroniclesLogLevel}"
  );

  otherDeps = builtins.removeAttrs deps [ "nat_traversal" ];

  pathArgs =
    builtins.concatStringsSep " "
      (builtins.concatMap (p: [ "--path:${p}" "--path:${p}/src" ])
        (builtins.attrValues otherDeps));
in
pkgs.stdenv.mkDerivation {
  pname = "wakucanary";
  version = "dev";

  inherit src;

  nativeBuildInputs = with pkgs; [
    nim-2_2
    git
    gnumake
    which
  ] ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [ pkgs.darwin.cctools ];

  buildInputs = [ zerokitRln ]
    ++ pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.stdenv.cc.cc.lib ];

  buildPhase = ''
    export HOME=$TMPDIR
    export XDG_CACHE_HOME=$TMPDIR/.cache
    export NIMBLE_DIR=$TMPDIR/.nimble
    export NIMCACHE=$TMPDIR/nimcache

    mkdir -p build $NIMCACHE

    NAT_TRAV=$TMPDIR/nat_traversal
    cp -r ${deps.nat_traversal} $NAT_TRAV
    chmod -R +w $NAT_TRAV

    make -C $NAT_TRAV/vendor/miniupnp/miniupnpc \
      CFLAGS="-Os -fPIC" build/libminiupnpc.a

    make -C $NAT_TRAV/vendor/libnatpmp-upstream \
      CFLAGS="-Wall -Os -fPIC -DENABLE_STRNATPMPERR -DNATPMP_MAX_RETRIES=4" libnatpmp.a

    echo "== Building wakucanary =="
    nim c \
      --noNimblePath \
      ${pathArgs} \
      --path:. \
      --path:$NAT_TRAV \
      --path:$NAT_TRAV/src \
      --passL:"-L${zerokitRln}/lib -lrln${pkgs.lib.optionalString pkgs.stdenv.isLinux " -lstdc++"}" \
      ${nimDefineArgs} \
      --threads:on \
      --mm:refc \
      --out:build/wakucanary \
      --nimcache:$NIMCACHE \
      apps/wakucanary/wakucanary.nim
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/lib
    cp build/wakucanary $out/bin/
    runHook postInstall
  '';

  # Bundle librln next to the binary so wakucanary is self-contained.
  postInstall =
    pkgs.lib.optionalString pkgs.stdenv.isDarwin ''
      cp ${zerokitRln}/lib/librln.dylib $out/lib/
      chmod +w $out/lib/librln.dylib $out/bin/wakucanary
      install_name_tool -id @rpath/librln.dylib $out/lib/librln.dylib
      old=$(otool -L $out/bin/wakucanary | awk 'NR>1{print $1}' | grep librln || true)
      if [ -n "$old" ]; then
        install_name_tool -change "$old" @rpath/librln.dylib $out/bin/wakucanary
      fi
      install_name_tool -add_rpath @loader_path/../lib $out/bin/wakucanary
    ''
    + pkgs.lib.optionalString pkgs.stdenv.isLinux ''
      cp ${zerokitRln}/lib/librln.so $out/lib/
      patchelf --add-rpath '$ORIGIN/../lib' $out/bin/wakucanary
    '';
}
