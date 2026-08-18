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

  # Every one of these runs on the BUILDER, so they must come from
  # buildPackages: in a cross package set `pkgs.git` is a git cross-compiled
  # FOR Windows, and `pkgs.nim-2_2` is the mingw-hosted nim wrapper, which does
  # not even evaluate (it wants a Windows bash). `buildPackages.nim-2_2` is the
  # `x86_64-w64-mingw32-nim` wrapper: it runs on the builder, has os/cpu baked
  # into its nim.cfg, and takes its backend from $CC at invocation time -- which
  # the cross stdenv has already set to x86_64-w64-mingw32-gcc.
  # Identity on every native system.
  buildTools = with pkgs.buildPackages; [ nim-2_2 git gnumake which ];

  # Binary app targets built as executables; anything else builds the FFI library.
  appSources = {
    wakucanary        = "apps/wakucanary/wakucanary.nim";
    logosdeliverynode = "apps/logos_delivery_node/logosdeliverynode.nim";
  };
  appTarget =
    let requested = builtins.filter (t: builtins.hasAttr t appSources) targets;
    in if requested == [] then null else builtins.head requested;
  buildApp = appTarget != null;

  # nim appends .exe itself on Windows, so the installed name differs from --out.
  exeSuffix = lib.optionalString isWindows ".exe";

  nimDefineArgs = lib.concatStringsSep " \\\n      " (
       [ "--define:disable_libbacktrace"
         "--define:git_version=${gitVersion}" ]
    ++ lib.optional enablePostgres       "--define:postgres"
    ++ lib.optional enableNimDebugDlOpen "--define:nimDebugDlOpen"
    ++ lib.optional (chroniclesLogLevel != null)
         "--define:chronicles_log_level=${toString chroniclesLogLevel}"
  );

  # These are excluded from the static pathArgs and handled separately in
  # buildPhase, because each needs a WRITABLE copy of its source tree:
  #  - nat_traversal: its bundled C libs must be compiled before linking.
  #  - boringssl (Windows only): the Windows branch of boringssl.nim both
  #    assembles .obj files into its own source dir (`outDir = baseDir`) and
  #    needs a two-line patch; see the sed in buildPhase.
  copiedDeps = [ "nat_traversal" ] ++ lib.optional isWindows "boringssl";
  otherDeps = builtins.removeAttrs deps copiedDeps;

  boringsslPathArgs =
    lib.optionalString isWindows "--path:$BORINGSSL --path:$BORINGSSL/src";

  # Some packages (e.g. regex, unicodedb) put their .nim files under src/
  # while others use the repo root. Pass both so the compiler finds either layout.
  pathArgs =
    builtins.concatStringsSep " "
      (builtins.concatMap (p: [ "--path:${p}" "--path:${p}/src" "--path:${p}/sds" ])
        (builtins.attrValues otherDeps));

  libExt =
    if isWindows then "dll"
    else if hostPlatform.isDarwin then "dylib"
    else "so";

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

  # The public header library/liblogosdelivery.h does
  #     #include "generated/logosdelivery.h"
  # and that file is a BUILD ARTIFACT, emitted by nim-ffi only when these
  # defines are passed -- see `cBindingsFlags` at logos_delivery.nimble:111-117,
  # which the Makefile path passes and this derivation did not. Without them the
  # header is never generated and never installed, so every consumer of the
  # installed include/ dir dies with
  #     fatal error: generated/logosdelivery.h: No such file or directory
  # on EVERY platform. Found by cross-building logos-delivery-module.
  #
  # -d:ffiSrcPath is not optional: without it nim-ffi derives the path with
  # relativePath, which needs getcwd at compile time and fails to build.
  cBindingsDir = "library/generated";
  # ffiOutputDir is handed to a compile-time writeFile, so a RELATIVE value is
  # resolved against whatever directory the nim VM considers current -- which is
  # not reliably the source root (the nimble task gets away with it because it
  # execs from there). $PWD is expanded by the shell before nim ever sees it, so
  # the codegen lands in the source tree no matter what the VM's cwd is.
  cBindingsArgs = [
    # THE load-bearing flag. nim-ffi emits via compile-time createDir/writeFile,
    # and Nim gates VM filesystem writes behind this: without it both calls
    # SILENTLY do nothing -- no exception, no warning -- so genBindings() reports
    # success having written zero files. Upstream passes the four defines below
    # but not this, which is why the header has never been produced on any
    # platform. See logos-messaging/logos-delivery#4121.
    "--experimental:vmopsDanger"
    "--define:ffiGenBindings"
    "--define:targetLang=c"
    "--define:ffiOutputDir=$PWD/${cBindingsDir}"
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
      --path:$NAT_TRAV/src ${boringsslPathArgs} \
      --passL:"${linkArgs}" \
      ${nimDefineArgs} \
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

    # nim-boringssl needs a writable source tree on Windows: linkAsmFiles sets
    # outDir = baseDir, so nasm writes .obj/.md5 next to the sources -- and in
    # the store that directory is read-only.
    BORINGSSL=$TMPDIR/boringssl
    cp -r ${deps.boringssl} $BORINGSSL
    chmod -R +w $BORINGSSL

    # boringssl.nim reaches its own sources through paths that are '\'-separated
    # as soon as os=Windows, which a POSIX builder cannot open. Two fixes, both
    # matching what lines 327/337 of the same file already do for nasm:
    #   1. baseDir comes from parentDir, which returns DirSep-separated text.
    #   2. the two joins feeding staticRead use nim's `/`, which joins on DirSep
    #      (the other two are already wrapped in normalizePath(dirSep = '/')).
    # Invisible on MSYS2, where the filesystem accepts either separator.
    sed -i "s|const baseDir = currentSourcePath.parentDir|const baseDir = normalizePath(currentSourcePath.parentDir, dirSep = '/')|" $BORINGSSL/boringssl.nim
    sed -i "/normalizePath/!s|baseDir /|baseDir \& \"/\" \&|" $BORINGSSL/boringssl.nim
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
      ++ cBindingsArgs;
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
      ] ++ cBindingsArgs;
    }}

    # nim-ffi emits its generated binding with `outputDir / name`, and Nim's `/`
    # normalises to the TARGET's separator. Building for Windows from a Linux
    # host makes that a BACKSLASH, and it converts the WHOLE path, not just the
    # final join -- so an absolute -d:ffiOutputDir=/build/.../library/generated
    # becomes the single relative filename
    #
    #     \build\...\library\generated\logosdelivery.h
    #
    # which the compile-time writeFile then creates in the CURRENT directory.
    # The requested output directory is left empty and the header appears at the
    # source root under a name nothing looks for.
    #
    # Reduced to a 7-line program rather than inferred. The same file built
    # natively and with --os:windows:
    #
    #     native : out/mylib.h, out/CMakeLists.txt
    #     windows: ./\tmp\ffi2\out\mylib.h, ./\tmp\ffi2\out\CMakeLists.txt
    #
    # That is why liblogosdelivery.h -- which #includes generated/logosdelivery.h
    # -- could never be compiled against on Windows. Convert the separators back
    # and move each file where it was meant to go. Inert on a native target,
    # where the name never contains a backslash and this loop matches nothing.
    #
    # The root cause belongs upstream in nim-ffi: its emitter runs on the HOST at
    # compile time, so it must use host path semantics, not the target's.
    while IFS= read -r bs; do
      [ -e "$bs" ] || continue
      target=$(printf '%s' "''${bs#./}" | tr '\\' '/')
      case "$target" in /*) ;; *) target="$PWD/$target" ;; esac
      mkdir -p "$(dirname "$target")"
      mv -f "$bs" "$target"
      echo "normalised cross-DirSep artifact -> $target"
    done < <(find . -maxdepth 1 -type f -name '*\\*' 2>/dev/null)
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

    # The generated C binding. liblogosdelivery.h #includes it, so an include/
    # without it cannot be compiled against at all -- which is how this surfaced:
    # every consumer died on "fatal error: generated/logosdelivery.h: No such
    # file or directory".
    #
    # Two things had to be true for it to appear, and both are handled above:
    # nim-ffi emits via compile-time createDir/writeFile, which Nim gates behind
    # --experimental:vmopsDanger (without it both calls silently do nothing), and
    # on a cross-to-Windows build the path it writes to is joined with the
    # TARGET's backslash, which the normalisation in buildPhase puts back.
    #
    # Now that both halves are fixed, a missing header is a real regression, so
    # fail instead of shipping an include/ that cannot compile.
    if [ -f ${cBindingsDir}/logosdelivery.h ]; then
      mkdir -p $out/include/generated
      cp ${cBindingsDir}/logosdelivery.h $out/include/generated/
    elif grep -q 'generated/logosdelivery.h' library/liblogosdelivery.h 2>/dev/null; then
      echo "error: genBindings() produced no ${cBindingsDir}/logosdelivery.h," >&2
      echo "       but library/liblogosdelivery.h #includes generated/logosdelivery.h." >&2
      echo "       The installed include/ would not compile. See logos-delivery#4121." >&2
      echo "       Contents of ${cBindingsDir}:" >&2
      ls -la ${cBindingsDir} >&2 || true
      echo "       Any files still carrying a target-separator name (the" >&2
      echo "       normalisation above should have moved these):" >&2
      find . -maxdepth 1 -type f -name '*\\*' >&2 2>/dev/null || true
      exit 1
    fi
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
