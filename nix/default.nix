{ pkgs
, src
, zerokitRln
, targets              ? []
, gitVersion           ? "n/a"
, enablePostgres       ? true
  # The libpq shipped beside a Windows app. NOT named `libpq`: callPackage would
  # auto-fill that name from `pkgs`, whose cross libpq does not build for mingw.
, libpqPackage         ? null
, enableNimDebugDlOpen ? true
, chroniclesLogLevel   ? null
}:

let
  deps      = import ./deps.nix    { inherit pkgs; };

  inherit (pkgs) lib;
  hostPlatform = pkgs.stdenv.hostPlatform;
  isWindows    = hostPlatform.isWindows;

  # nixpkgs' TinyCBOR install target drops the .exe suffix from cbordump when
  # cross-compiling. Consumers only need the static library and public headers.
  tinycbor =
    if !isWindows then pkgs.tinycbor
    else pkgs.tinycbor.overrideAttrs (old: {
      makeFlags = (old.makeFlags or []) ++ [ "BUILD_SHARED=0" "BUILD_STATIC=1" ];
      postPatch = (old.postPatch or "") + ''
        substituteInPlace Makefile \
          --replace-fail 'INSTALL_TARGETS += $(bindir)/cbordump' \
                         '# cbordump is not installed when cross-compiling'
      '';
    });

  # These run on the BUILDER, so buildPackages: `pkgs.nim-2_2` is the
  # mingw-hosted wrapper and does not evaluate. Identity on a native system.
  buildTools = with pkgs.buildPackages; [ nim-2_2 git gnumake which cmake ];

  # Binary app targets built as executables; anything else builds the FFI library.
  appSources = {
    wakucanary        = "apps/wakucanary/wakucanary.nim";
    logosdeliverynode = "apps/logos_delivery_node/logosdeliverynode.nim";
  };
  appTarget =
    let requested = builtins.filter (t: builtins.hasAttr t appSources) targets;
    in if requested == [] then null else builtins.head requested;
  buildApp = appTarget != null;

  # Build-specific defines only. Feature defines live in config.nims.
  # nim appends .exe itself on Windows, so the installed name differs from --out.
  exeSuffix = lib.optionalString isWindows ".exe";

  nimDefineArgs = lib.concatStringsSep " \\\n      " (
       [ "--define:disable_libbacktrace"
         "--define:libp2p_mix_experimental_exit_is_dest"
         "--define:libp2p_quic_support"
         "--define:git_version=${gitVersion}" ]
    ++ lib.optional enablePostgres       "--define:postgres"
    ++ lib.optional enableNimDebugDlOpen "--define:nimDebugDlOpen"
    ++ lib.optional (chroniclesLogLevel != null)
         "--define:chronicles_log_level=${toString chroniclesLogLevel}"
  );

  # nat_traversal is handled separately in buildPhase: its bundled C libs must
  # be compiled before linking, which needs a writable copy of its source tree.
  copiedDeps = [ "nat_traversal" ];
  otherDeps = builtins.removeAttrs deps copiedDeps;

  # nixpkgs' MinGW toolchain has no OpenMP runtime to link Leopard-RS against.
  leopardDefineArgs = lib.optionals isWindows [
    "--define:LeopardExtraCompilerFlags=-fno-openmp"
    "--define:LeopardExtraLinkerFlags=-fno-openmp"
  ];

  # Some packages (e.g. regex, unicodedb) put their .nim files under src/
  # while others use the repo root. Pass both so the compiler finds either layout.
  # /sds and /segmentation are those packages' nimble srcDir: nix hands us the
  # raw checkout, not the flattened layout `nimble install` would produce.
  pathArgs =
    builtins.concatStringsSep " "
      (builtins.concatMap (p: [
        "--path:${p}"
        "--path:${p}/src"
        "--path:${p}/sds"
        "--path:${p}/segmentation"
      ])
        (builtins.attrValues otherDeps));

  libExt =
    if isWindows then "dll"
    else if hostPlatform.isDarwin then "dylib"
    else "so";

  # Mirrors the nimble buildLibrary proc: library targets only, not the apps.
  libDefineArgs = [ "--define:discv5_protocol_id=d5waku" ];

  # The .dll belongs in bin/: nixpkgs' win-dll-link hook only stages a PE's
  # dependency DLLs under $prefix/bin, so one in lib/ cannot load.
  dllDir = if isWindows then "bin" else "lib";

  # The public header includes this generated surface. Keep the path absolute:
  # nim-ffi writes it from the compile-time VM (nim-ffi#168).
  cBindingsDir = "library/generated";
  cBindingsArgs = [
    "--define:ffiGenBindings"
    "--define:targetLang=c"
    "--define:ffiOutputDir=$PWD/${cBindingsDir}"
    # Avoid compile-time getcwd in nim-ffi's default relative-path derivation.
    "--define:ffiSrcPath=../liblogosdelivery.nim"
  ];

  # Win32 imports for the Nim runtime, chronos and the static rln: the MSYS2
  # set, plus dbghelp, stdc++ (boringssl) and winpthread (clock_gettime64).
  windowsLinkFlags =
    "-lws2_32 -lbcrypt -liphlpapi -luserenv -lntdll -ldbghelp"
    + " -lwinpthread -lstdc++"
    + " -Wl,--allow-multiple-definition";

  linkArgs =
    if isWindows then
      # No -lrln: config.nims already links $LIBRLN_FILE on Windows, so adding
      # it here would link the same 27 MB archive twice.
      windowsLinkFlags
    else
      "-L${zerokitRln}/lib -lrln"
      + lib.optionalString hostPlatform.isLinux " -lstdc++";

  # Shared `nim c` invocation; callers vary only the output, source and a few
  # mode flags. $NAT_TRAV and $NIMCACHE come from buildPhase.
  nimCompile = { outFile, sourceFile, extraArgs ? [] }: ''
    nim c \
      --noNimblePath \
      ${pathArgs} \
      --path:$NAT_TRAV \
      --path:$NAT_TRAV/src \
      --passL:"${linkArgs}" \
      ${nimDefineArgs} \
      ${lib.concatStringsSep " \\\n      " leopardDefineArgs} \
      --threads:on \
      --mm:refc \
      --nimcache:$NIMCACHE \
      --out:${outFile} \
      ${lib.concatStringsSep " \\\n      " extraArgs} \
      ${sourceFile}
  '';

  # Both vendored makefiles take their target from `$(CC) -dumpmachine`, so the
  # cross compiler selects MinGW; CC= on the command line beats their own CC.
  natMakeVars = lib.optionalString isWindows ''CC="$CC" AR="$AR" RANLIB="$RANLIB"'';
  # -fPIC is meaningless on PE (everything is relocatable) and gcc warns on it.
  natPic = lib.optionalString (!isWindows) " -fPIC";
  # Both vendored headers make LIBSPEC __declspec(dllimport) unless
  # <LIB>_STATICLIB is set, so each archive calls its own symbols through stubs.
  upnpStatic   = lib.optionalString isWindows " -DMINIUPNP_STATICLIB";
  natpmpStatic = lib.optionalString isWindows " -DNATPMP_STATICLIB";
in
pkgs.stdenv.mkDerivation {
  pname = if buildApp then appTarget else "liblogosdelivery";
  version = "dev";

  inherit src;

  nativeBuildInputs = buildTools
    ++ lib.optionals hostPlatform.isDarwin [ pkgs.buildPackages.darwin.cctools ]
    # Only the Windows branch of nim-boringssl has hand-written asm, and it
    # shells out to `nasm -f win64` from a compile-time macro.
    ++ lib.optionals isWindows [ pkgs.buildPackages.nasm ];

  buildInputs = [ zerokitRln ]
    ++ lib.optionals hostPlatform.isLinux [ pkgs.stdenv.cc.cc.lib ]
    # nixpkgs builds mingw-w64 against mcfgthread, so nothing in the default
    # closure provides pthread.h / libpthread.a.
    ++ lib.optionals isWindows [ pkgs.windows.pthreads ];

  # cmake is here only for nim-leopard's own CMakeLists; without this its setup
  # hook makes cmakeConfigurePhase the configurePhase and fails on the repo root.
  dontUseCmakeConfigure = true;

  # The generated C helpers include <tinycbor/cbor.h> and call TinyCBOR's
  # encoder/decoder API. Propagate it from the library package to consumers.
  propagatedBuildInputs = lib.optionals (!buildApp) [ tinycbor ];

  buildPhase = ''
    export HOME=$TMPDIR
    export XDG_CACHE_HOME=$TMPDIR/.cache
    export NIMBLE_DIR=$TMPDIR/.nimble
    export NIMCACHE=$TMPDIR/nimcache

    mkdir -p build $NIMCACHE ${cBindingsDir}

    # nat_traversal bundles C sub-libraries that must be compiled before linking.
    # Copy the fetchgit store path to a writable tmpdir, build, then pass to nim.
    NAT_TRAV=$TMPDIR/nat_traversal
    cp -r ${deps.nat_traversal} $NAT_TRAV
    chmod -R +w $NAT_TRAV

    make -C $NAT_TRAV/vendor/miniupnp/miniupnpc ${natMakeVars} \
      CFLAGS="-Os${natPic}${upnpStatic}" build/libminiupnpc.a

    make -C $NAT_TRAV/vendor/libnatpmp-upstream ${natMakeVars} \
      CFLAGS="-Wall -Os${natPic} -DENABLE_STRNATPMPERR -DNATPMP_MAX_RETRIES=4${natpmpStatic}" libnatpmp.a
    ${lib.optionalString isWindows ''
    # nim-nat-traversal wants libminiupnpc.a at the miniupnpc root on Windows,
    # but Makefile.mingw has to RUN a .exe: build portable, then stage it there.
    cp $NAT_TRAV/vendor/miniupnp/miniupnpc/build/libminiupnpc.a \
       $NAT_TRAV/vendor/miniupnp/miniupnpc/libminiupnpc.a

    # nim shells out to a bare `ar` for --app:staticlib and a cross stdenv has
    # only x86_64-w64-mingw32-ar; every archive built here is for the target.
    mkdir -p $TMPDIR/arshim
    ln -sf "$(command -v $AR)" $TMPDIR/arshim/ar
    export PATH=$TMPDIR/arshim:$PATH

    # config.nims links rln statically on Windows, as MSYS2 does, from the
    # archive this variable names -- so no rln DLL ships.
    export LIBRLN_FILE=${zerokitRln}/lib/librln.a
    ''}

    ${if buildApp then ''
    echo "== Building ${appTarget} =="
    ${nimCompile {
      outFile = "build/${appTarget}";
      sourceFile = appSources.${appTarget};
      extraArgs = [ "--path:." ];
    }}
    '' else ''
    echo "== Building liblogosdelivery (dynamic) =="
    ${nimCompile {
      outFile = "build/liblogosdelivery.${libExt}";
      sourceFile = "library/liblogosdelivery.nim";
      extraArgs = [
        "--app:lib"
        "--opt:size"
        "--noMain"
        "--header"
        "--nimMainPrefix:liblogosdelivery"
      ]
      # nim emits only the .dll, and find_library ignores a bare .dll, so a
      # consumer would fall through to the .a and link the Nim runtime statically.
      ++ lib.optional isWindows
           "--passL:-Wl,--out-implib,build/liblogosdelivery.dll.a"
      ++ libDefineArgs ++ cBindingsArgs;
    }}

    echo "== Building liblogosdelivery (static) =="
    ${nimCompile {
      outFile = "build/liblogosdelivery.a";
      sourceFile = "library/liblogosdelivery.nim";
      extraArgs = [
        "--app:staticlib"
        "--opt:size"
        "--noMain"
        "--nimMainPrefix:liblogosdelivery"
      ] ++ libDefineArgs ++ cBindingsArgs;
    }}

    ''}
  '';

  installPhase = if buildApp then ''
    runHook preInstall
    mkdir -p $out/bin $out/lib
    cp build/${appTarget}${exeSuffix} $out/bin/
${lib.optionalString (isWindows && libpqPackage != null) ''
    # `-d:postgres` binds libpq through a {.dynlib.} resolved before main(), and
    # a bare-name load searches the exe's own directory: ship bin/*.dll beside it.
    cp -L ${libpqPackage}/bin/*.dll $out/bin/
    chmod u+w $out/bin/*.dll
''}
    runHook postInstall
  '' else ''
    runHook preInstall
    mkdir -p $out/lib $out/include${lib.optionalString isWindows " $out/bin"}
    cp build/liblogosdelivery.${libExt} $out/${dllDir}/ 2>/dev/null || true
    cp build/liblogosdelivery.a         $out/lib/ 2>/dev/null || true
${lib.optionalString isWindows ''
    # The import library belongs in lib/ (a link-time input), beside the static
    # archive; only the .dll is a runtime artifact and lives in bin/.
    if [ ! -f build/liblogosdelivery.dll.a ]; then
      echo "error: no import library was produced -- consumers cannot link the DLL" >&2
      exit 1
    fi
    cp build/liblogosdelivery.dll.a $out/lib/
''}
    cp library/liblogosdelivery.h        $out/include/ 2>/dev/null || true
    cp library/liblogosdelivery_kernel.h $out/include/ 2>/dev/null || true
    cp library/liblogosdelivery_rln.h    $out/include/ 2>/dev/null || true

    # The public header includes the generated binding, which in turn includes
    # nim-ffi's CBOR helpers. Fail rather than ship an incomplete include tree.
    for header in logosdelivery.h nim_ffi_cbor.h nim_ffi_prelude.h; do
      if [ ! -f ${cBindingsDir}/$header ]; then
        echo "error: genBindings() produced no ${cBindingsDir}/$header." >&2
        echo "       The installed include/ would not compile. See logos-delivery#4121." >&2
        echo "       Contents of ${cBindingsDir}:" >&2
        ls -la ${cBindingsDir} >&2 || true
        exit 1
      fi
    done
    mkdir -p $out/include/generated
    cp ${cBindingsDir}/*.h $out/include/generated/
    runHook postInstall
  '';

  # Bundle librln beside the artifact; --add-rpath keeps fixupPhase's own RUNPATH.
  # On Windows a copy next to the image IS the fixup, and rln may be static-only.
  postInstall =
    lib.optionalString isWindows ''
      # Nothing to do: rln links statically, and win-dll-link stages the PE's
      # own imports because installPhase put the .dll in $out/bin (see dllDir).
      true
    ''
    + lib.optionalString (!isWindows) (
    if buildApp then
      lib.optionalString hostPlatform.isDarwin ''
        cp ${zerokitRln}/lib/librln.dylib $out/lib/
        chmod +w $out/lib/librln.dylib $out/bin/${appTarget}
        install_name_tool -id @rpath/librln.dylib $out/lib/librln.dylib
        old=$(otool -L $out/bin/${appTarget} | awk 'NR>1{print $1}' | grep librln || true)
        if [ -n "$old" ]; then
          install_name_tool -change "$old" @rpath/librln.dylib $out/bin/${appTarget}
        fi
        install_name_tool -add_rpath @loader_path/../lib $out/bin/${appTarget}
      ''
      + lib.optionalString hostPlatform.isLinux ''
        cp ${zerokitRln}/lib/librln.so $out/lib/
        patchelf --add-rpath '$ORIGIN/../lib' $out/bin/${appTarget}
      ''
    else
      lib.optionalString hostPlatform.isDarwin ''
        cp ${zerokitRln}/lib/librln.dylib $out/lib/
        chmod +w $out/lib/librln.dylib $out/lib/liblogosdelivery.dylib
        install_name_tool -id @rpath/liblogosdelivery.dylib $out/lib/liblogosdelivery.dylib
        install_name_tool -id @rpath/librln.dylib $out/lib/librln.dylib
        old=$(otool -L $out/lib/liblogosdelivery.dylib | awk 'NR>1{print $1}' | grep librln)
        install_name_tool -change "$old" @rpath/librln.dylib $out/lib/liblogosdelivery.dylib
        install_name_tool -add_rpath @loader_path $out/lib/liblogosdelivery.dylib
      ''
      + lib.optionalString hostPlatform.isLinux ''
        cp ${zerokitRln}/lib/librln.so $out/lib/
        patchelf --add-rpath '$ORIGIN' $out/lib/liblogosdelivery.so
      '');

  meta = with pkgs.lib; {
    description =
      if buildApp
      then "logos-delivery ${appTarget} binary"
      else "logos-delivery shared/static library";
    homepage = "https://github.com/logos-messaging/logos-delivery";
    license  = licenses.mit;
    # Test Windows FIRST when branching on platform: under mingw cross, isDarwin
    # and isAarch64 are false and x86_64 still matches.
    platforms = platforms.unix ++ platforms.windows;
  };
}
