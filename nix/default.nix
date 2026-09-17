{ pkgs
, src
, zerokitRln
, targets              ? []
, gitVersion           ? "n/a"
, enablePostgres       ? true
  # The libpq to ship beside an app target on Windows. NOT named `libpq`:
  # callPackage auto-fills an argument by that name from `pkgs`, and in the
  # cross package set `pkgs.libpq` is the un-overridden one that does not build
  # for mingw -- so a default would be silently replaced by a broken value.
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

  # Every one of these runs on the BUILDER, so they must come from
  # buildPackages: in a cross package set `pkgs.git` is a git cross-compiled
  # FOR Windows, and `pkgs.nim-2_2` is the mingw-hosted nim wrapper, which does
  # not even evaluate (it wants a Windows bash). `buildPackages.nim-2_2` is the
  # `x86_64-w64-mingw32-nim` wrapper: it runs on the builder, has os/cpu baked
  # into its nim.cfg, and takes its backend from $CC at invocation time -- which
  # the cross stdenv has already set to x86_64-w64-mingw32-gcc.
  # Identity on every native system.
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

  # Windows splits a shared library in two: the import/static half is a link-time
  # artifact and belongs in lib/, but the .dll is a RUNTIME artifact and belongs
  # in bin/ -- that is CMake's own RUNTIME destination, and what openssl,
  # postgres and every autotools port in this closure already do.
  #
  # Following it is not cosmetic. nixpkgs' win-dll-link hook stages a PE's
  # dependency DLLs automatically, but its fixup only ever walks $prefix/bin, so
  # a .dll in lib/ ships with none of libgcc_s_seh-1 / libstdc++-6 /
  # libwinpthread-1 beside it and fails to load on Windows with no diagnostic.
  # Putting it in bin/ gets that staging for free instead of hand-rolling it.
  dllDir = if isWindows then "bin" else "lib";

  # The public header includes this generated call surface. Keep the output
  # absolute because nim-ffi writes it from the compile-time VM; the pinned
  # version uses build-host path separators when cross-compiling (nim-ffi#168).
  cBindingsDir = "library/generated";
  cBindingsArgs = [
    "--define:ffiGenBindings"
    "--define:targetLang=c"
    "--define:ffiOutputDir=$PWD/${cBindingsDir}"
    # Avoid compile-time getcwd in nim-ffi's default relative-path derivation.
    "--define:ffiSrcPath=../liblogosdelivery.nim"
  ];

  # Win32 imports the Nim runtime, chronos and a statically linked rln need.
  # These are exactly the ones the MSYS2 build passes; --allow-multiple-definition
  # is needed for the same reason it is there (duplicate symbols between the
  # mingw runtime and the Rust staticlib).
  # Win32 imports needed by the Nim runtime, chronos and the statically linked
  # rln -- the same set the MSYS2 build passes, plus:
  #   -ldbghelp     the Rust staticlib's backtrace support
  #   -lstdc++      boringssl is C++, but nim drives the link through gcc, not
  #                 g++, so nothing pulls in the C++ runtime or
  #                 __gxx_personality_seh0
  #   -lwinpthread  winpthreads' pthread_time.h inlines clock_gettime as a call
  #                 to clock_gettime64, which lives in libwinpthread; having the
  #                 headers on the include path is not enough (lsquic hits this)
  # --allow-multiple-definition is what the MSYS2 build uses too: the mingw
  # runtime and the Rust staticlib both define some symbols.
  windowsLinkFlags =
    "-lws2_32 -lbcrypt -liphlpapi -luserenv -lntdll -ldbghelp"
    + " -lwinpthread -lstdc++"
    + " -Wl,--allow-multiple-definition";

  linkArgs =
    if isWindows then
      # No -lrln here: the repo's own config.nims:8-9 already does
      # `switch("passL", "rln.lib")` on Windows, matching the Makefile's
      # LIBRLN_FILE. buildPhase stages the static archive under that name, so
      # adding -lrln as well would link the same 27 MB archive twice.
      windowsLinkFlags
    else
      "-L${zerokitRln}/lib -lrln"
      + lib.optionalString hostPlatform.isLinux " -lstdc++";

  # Shared `nim c` invocation. Callers vary the output, the source file and a
  # few mode-specific flags (e.g. --app:lib, --noMain, --header); everything
  # else (paths, defines, threading, gc, nimcache, rln linkage) is constant.
  # $NAT_TRAV and $NIMCACHE are shell variables defined in buildPhase.
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

  # Both vendored makefiles derive their target from `$(CC) -dumpmachine`
  # (miniupnpc Makefile:13, libnatpmp Makefile:7) rather than uname, so handing
  # them the cross compiler is enough to select the MinGW branch. Note that
  # libnatpmp's MinGW branch then assigns `CC = i686-w64-mingw32-gcc` -- a
  # command-line CC= overrides that, a CFLAGS-only invocation would not.
  natMakeVars = lib.optionalString isWindows ''CC="$CC" AR="$AR" RANLIB="$RANLIB"'';
  # -fPIC is meaningless on PE (everything is relocatable) and gcc warns on it.
  natPic = lib.optionalString (!isWindows) " -fPIC";
  # Both vendored headers resolve their LIBSPEC to __declspec(dllimport) on
  # _WIN32 unless <LIB>_STATICLIB is defined (miniupnpc_declspec.h:6,
  # natpmp_declspec.h:4). nim-nat-traversal defines them for the nim-generated
  # C (miniupnpc.nim:40, natpmp.nim:30) but NOT for the vendored library build,
  # so each archive ends up calling its OWN symbols through import stubs:
  # "undefined reference to `__imp_upnpDiscoverDevices'".
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
    # nixpkgs builds mingw-w64 against mcfgthread, so pthread.h / libpthread.a
    # exist nowhere in the default closure; anything carrying a POSIX-threads
    # assumption (the Rust staticlib, some vendored C) needs this on the path.
    ++ lib.optionals isWindows [ pkgs.windows.pthreads ];

  # cmake is here only so nim-leopard can build Leopard-RS from its own
  # CMakeLists during `nim c`. Without this, cmake's setup hook installs
  # cmakeConfigurePhase as the derivation's configurePhase and fails on the
  # repo root, which has no CMakeLists.txt of its own.
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
    # nim-nat-traversal expects libminiupnpc.a at the miniupnpc ROOT on Windows
    # and under build/ everywhere else -- see the "the Makefiles of the miniupnp
    # library have an inconsistency" comment in nat_traversal/miniupnpc.nim.
    # That root layout is what Makefile.mingw produces, but Makefile.mingw
    # generates miniupnpcstrings.h by building and RUNNING a .exe, which a Linux
    # builder cannot do. So: build with the portable Makefile, then stage the
    # archive where the Windows branch of the nim wrapper looks for it.
    cp $NAT_TRAV/vendor/miniupnp/miniupnpc/build/libminiupnpc.a \
       $NAT_TRAV/vendor/miniupnp/miniupnpc/libminiupnpc.a

    # For --app:staticlib nim shells out to a bare `ar`, and a cross stdenv has
    # only x86_64-w64-mingw32-ar on PATH: the nixpkgs nim wrapper rewrites
    # gcc.exe/gcc.linkerexe from $CC/$CXX but never the archiver, and nim
    # exposes no config key for it. Every archive produced in this phase is for
    # the target, so shadowing ar with $AR is correct and not merely expedient.
    mkdir -p $TMPDIR/arshim
    ln -sf "$(command -v $AR)" $TMPDIR/arshim/ar
    export PATH=$TMPDIR/arshim:$PATH

    # config.nims adds `--passL:rln.lib` on Windows, resolved relative to the
    # project root. Link rln statically there, exactly as the MSYS2 build does
    # via LIBRLN_FILE -- so no rln DLL needs to ship alongside.
    cp ${zerokitRln}/lib/librln.a rln.lib

    # config.nims picks the MSYS CMake generator from the TARGET OS, which a
    # Linux builder does not have; OpenMP is off for the reason given above.
    substituteInPlace config.nims \
      --replace-fail '-G\"MSYS Makefiles\" -DCMAKE_BUILD_TYPE=Release' \
                     '-DCMAKE_BUILD_TYPE=Release -DENABLE_OPENMP=off'
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
      # A Windows shared library is TWO artifacts: consumers LINK against the
      # import library and SHIP the .dll. nim emits only the .dll, and CMake's
      # find_library will not return a bare .dll -- so a consumer silently falls
      # through to liblogosdelivery.a and tries to link the whole Nim runtime
      # statically, which then fails on every rln/setjmp symbol. Emitting the
      # import lib is what makes `-l logosdelivery` mean the DLL.
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
    # `-d:postgres` makes Nim's db_connector bind libpq through a module-level
    # {.dynlib.}, which the runtime resolves EAGERLY at process start -- so the
    # app cannot reach main() without it. On Windows a bare-name load searches
    # the image's own directory first and never the caller's, so "beside the
    # exe" is the only placement that works for a relocatable output.
    #
    # This is invisible to every static check: a dlopen leaves no entry in the
    # PE import table, so an import-closure gate passes on a binary that cannot
    # start. It was found by running --version on a real Windows box, where it
    # failed with `could not load: libpq.dll` before printing anything.
    #
    # bin/*.dll rather than libpq.dll alone: libpq imports libssl-3-x64.dll and
    # libcrypto-3-x64.dll, and those are subject to the same search order.
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

  # Bundle librln alongside the produced artifact so the output is self-contained.
  # Use --add-rpath (not --set-rpath) so fixupPhase's stdenv RUNPATH injection
  # for libstdc++ is preserved.
  #
  # Windows needs no path rewriting at all: a PE import table carries DLL BASE
  # NAMES and the loader searches the image's own directory first, so a plain
  # copy next to the artifact IS the fixup. rln may also be static-only here,
  # in which case there is no DLL to copy and the glob is a no-op.
  postInstall =
    lib.optionalString isWindows ''
      # Nothing to do. rln is linked statically from rln.lib, so no rln DLL
      # ships; and the PE's own imports (libgcc_s_seh-1, libstdc++-6,
      # libwinpthread-1) are staged automatically by nixpkgs' win-dll-link
      # hook, because installPhase put the .dll in $out/bin -- the one
      # directory that hook's fixup walks. See dllDir above.
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
    # Test Windows FIRST anywhere platforms are branched: under mingw cross
    # isDarwin and isAarch64 are both false and x86_64 still matches, so a
    # Unix-shaped list silently claims the target it cannot serve.
    platforms = platforms.unix ++ platforms.windows;
  };
}
