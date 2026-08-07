import std/[os, strutils]

# Package
version = "3.3.0"
author = "Nagy Zoltan Peter"
description =
  "Type-safe, decoupled messaging patterns for Nim / single thread, cross-thread and FFI API support!"
license = "MIT"
skipDirs = @["tests", "examples", "tools"]

# Dependencies
requires "nim >= 2.2.4"
requires "chronos >= 4.0.0"
requires "results >= 0.5.0"
requires "chronicles >= 0.10.0"
requires "testutils >= 0.5.0"
requires "cbor_serialization >= 0.3.0"

proc quoteArg(arg: string): string =
  if defined(windows):
    result = '"' & arg.replace("\"", "\"\"") & '"'
  else:
    result = '"' & arg.replace("\"", "\\\"") & '"'

proc compileVariantSuffix(env: string): string =
  let normalized = env.toLowerAscii()
  let memoryManager = if normalized.contains("--mm:refc"): "refc" else: "orc"
  let buildMode = if normalized.contains("-d:release"): "release" else: "debug"

  memoryManager & "_" & buildMode

proc findPythonExe(): string =
  result = findExe("python3")
  if result.len == 0:
    result = findExe("python")
  if result.len == 0:
    quit "Python interpreter not found. Install python3 or add it to PATH."

proc nimMainPrefixFlag(prefix: string): string =
  ## Returns "--nimMainPrefix:<prefix>" on POSIX and "" on Windows.
  ##
  ## --nimMainPrefix is a POSIX-only concern.  On POSIX, dlopen with
  ## RTLD_GLOBAL merges all shared-object exports into a single flat namespace,
  ## so two Nim .so files that both define NimMain collide; the prefix renames
  ## them (e.g. fooNimMain, barNimMain) to prevent that.
  ##
  ## On Windows the PE loader resolves every import as "DLL!Symbol", giving
  ## each DLL its own isolated namespace — foo.dll!NimMain and bar.dll!NimMain
  ## never clash, so the prefix is unnecessary.
  ##
  ## Using --nimMainPrefix on Windows also triggers a Nim codegen bug:
  ## the C generator forward-declares the prefixed NimMain without
  ## __declspec(dllexport) and then defines it with N_LIB_EXPORT, which both
  ## clang and GCC reject as a hard error (err_attribute_dll_redeclaration).
  when defined(windows):
    result = ""
  else:
    result = " --nimMainPrefix:" & prefix

proc nimWindowsCcFlag(): string =
  ## On Windows we standardize FFI builds on clang. Nim's default cc on
  ## Windows is MinGW gcc (msvcrt.dll), but the C/C++ side is built by
  ## cmake via Visual Studio + MSVC by default (ucrt.dll). Mixing two CRTs
  ## across the DLL boundary causes heap/stdio/TLS mismatches that surface
  ## as random crashes at process teardown. Forcing clang on the Nim side
  ## keeps both halves on a single CRT (MinGW msvcrt or release UCRT,
  ## depending on which clang the runner ships).
  when defined(windows): " --cc:clang" else: ""

proc nimWindowsImplibFlag(outDir, libName: string): string =
  ## Force lld to emit an import library at a known path next to the DLL.
  ##
  ## clang in gnu-driver mode (the only mode available when the runner
  ## ships MinGW-bundled clang under external/mingw-amd64/bin) defaults
  ## to ld.lld in gnu-mode, which does NOT auto-emit any import library.
  ## The cmake consumer then fails with "ninja: error: '<libName>.lib'
  ## missing and no known rule to make it" because our IMPORTED_IMPLIB
  ## cmake property points at that path.
  ##
  ## Passing `-Wl,--out-implib=<path>` makes lld write a gnu-format
  ## import library at the requested path. The file extension is purely
  ## conventional — we keep `.lib` so that the cmake IMPORTED_IMPLIB
  ## paths stay uniform across asan (MSVC-format .lib) and non-asan
  ## (gnu-format .lib) builds. Both formats are accepted by clang+lld
  ## consumers in gnu-driver mode.
  when defined(windows):
    " --passL:-Wl,--out-implib=" & outDir & "/" & libName & ".lib"
  else:
    ""

# NOTE: the historical `skipRefcOnWindows` predicate (refc excluded from the
# Windows MT/FFI matrix) was removed in the teardown-sequence fix. The crash
# it papered over was a worker-thread-exit UAF (live RegisterWaitForSingleObject
# registration + refc deallocOsPages), fixed by BrokerSignalShared +
# teardownBrokerThread in brokers/internal/mt_broker_common.nim and regression-
# gated by `nimble testAllocRace` (a Windows step in ci.yml) — see
# doc/LIMITATION.md §2.2. refc and orc run the identical matrix on every
# platform; if a regression ever reappears, the gate fails loudly.

proc memoryManagerMatrix(): seq[string] =
  ## Returns the set of `--mm:` values the wrapper / example tasks
  ## should iterate over.
  ##
  ## - If `MM` is set in the environment, honour the explicit choice
  ##   (e.g. `MM=refc nimble runTypeMapTestLibPy`) — run that one only.
  ## - Otherwise, run both `orc` and `refc` so the parity matrix is
  ##   exercised end-to-end under both memory managers, on every platform.
  if existsEnv("MM"):
    @[getEnv("MM")]
  else:
    @["orc", "refc"]

proc setMM(mm: string) =
  ## Helper for the matrix loops: pins `MM` for the duration of one
  ## library rebuild + foreign-side run. The matrix loop reassigns
  ## per iteration; the env var also leaks back to the caller's shell,
  ## but that's the same behaviour the existing single-shot tasks had.
  putEnv("MM", mm)

proc cmakeWindowsConfigureExtras(): string =
  ## On Windows we drive cmake with Ninja + clang/clang++ + lld, pin the
  ## release UCRT and select RelWithDebInfo. The default Visual Studio
  ## generator ignores CMAKE_*_COMPILER for the toolset and pulls in MSVC
  ## link.exe + the debug UCRT for Debug configs — both incompatible with
  ## the clang-built Nim DLLs.
  when defined(windows):
    " -G Ninja -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++" &
      " -DCMAKE_LINKER_TYPE=LLD -DCMAKE_BUILD_TYPE=RelWithDebInfo" &
      " -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL"
  else:
    ""

# FFI build of mylib.nim, emitting into nimlib/build/. Drives the
# C++ example through the generated mylib.h / mylib.hpp.
proc buildFfiExampleFlags(
    generatePy = false, generateRust = false, generateGo = false
): string =
  result =
    "-d:BrokerFfiApi --threads:on --app:lib --path:. --outdir:examples/ffiapi/nimlib/build"
  result.add(nimMainPrefixFlag("mylib"))
  result.add(nimWindowsCcFlag())
  result.add(nimWindowsImplibFlag("examples/ffiapi/nimlib/build", "mylib"))
  if existsEnv("MM"):
    result.add(" --mm:" & getEnv("MM"))
  else:
    result.add(" --mm:orc")
  if generatePy or existsEnv("GEN_PY"):
    result.add(" -d:BrokerFfiApiGenPy")
  if generateRust or existsEnv("GEN_RUST"):
    result.add(" -d:BrokerFfiApiGenRust")
  if generateGo or existsEnv("GEN_GO"):
    result.add(" -d:BrokerFfiApiGenGo")

proc buildFfiExampleLibrary(
    generatePy = false, generateRust = false, generateGo = false
) =
  exec "nim c " & buildFfiExampleFlags(generatePy, generateRust, generateGo) &
    " examples/ffiapi/nimlib/mylib.nim"

proc buildTorpedoExampleFlags(
    generatePy = false, generateRust = false, generateGo = false
): string =
  result =
    "-d:BrokerFfiApi --threads:on --app:lib --path:. --outdir:examples/torpedo/nimlib/build"
  result.add(nimMainPrefixFlag("torpedolib"))
  result.add(nimWindowsCcFlag())
  result.add(nimWindowsImplibFlag("examples/torpedo/nimlib/build", "torpedolib"))
  if existsEnv("MM"):
    result.add(" --mm:" & getEnv("MM"))
  else:
    result.add(" --mm:orc")
  if generatePy or existsEnv("GEN_PY"):
    result.add(" -d:BrokerFfiApiGenPy")
  if generateRust or existsEnv("GEN_RUST"):
    result.add(" -d:BrokerFfiApiGenRust")
  if generateGo or existsEnv("GEN_GO"):
    result.add(" -d:BrokerFfiApiGenGo")

proc buildTorpedoExampleLibrary(
    generatePy = false, generateRust = false, generateGo = false
) =
  exec "nim c " & buildTorpedoExampleFlags(generatePy, generateRust, generateGo) &
    " examples/torpedo/nimlib/torpedolib.nim"

proc ffiExamplesBuildDir(): string =
  "examples/ffiapi/cmake-build"

proc buildFfiCmakeTarget(target = "") =
  let cmakeDir = "examples/ffiapi"
  let buildDir = ffiExamplesBuildDir()
  mkDir(buildDir)
  exec "cmake -S " & cmakeDir & " -B " & buildDir & cmakeWindowsConfigureExtras()
  if target.len == 0:
    exec "cmake --build " & buildDir
  else:
    exec "cmake --build " & buildDir & " --target " & target

proc ffiExampleExecutablePath(exampleDir: string): string =
  when defined(windows):
    joinPath(exampleDir, "build", "example.exe")
  else:
    joinPath(exampleDir, "build", "example")

proc torpedoCmakeBuildDir(): string =
  "examples/torpedo/cmake-build"

proc buildTorpedoCmakeTarget(target = "") =
  let cmakeDir = "examples/torpedo"
  let buildDir = torpedoCmakeBuildDir()
  mkDir(buildDir)
  exec "cmake -S " & cmakeDir & " -B " & buildDir & cmakeWindowsConfigureExtras()
  if target.len == 0:
    exec "cmake --build " & buildDir
  else:
    exec "cmake --build " & buildDir & " --target " & target

proc torpedoExecutablePath(): string =
  when defined(windows):
    joinPath("examples", "torpedo", "cpp_example", "build", "torpedo.exe")
  else:
    joinPath("examples", "torpedo", "cpp_example", "build", "torpedo")

proc test(env, path: string) =
  let outputPath =
    joinPath("build", path & "_" & compileVariantSuffix(env)).addFileExt(ExeExt)
  let label = path & " [" & env & "]"
  exec "nim c " & env & " --path:. --out:" & quoteArg(outputPath) & " test/" & path &
    ".nim"
  echo "=== RUN  " & label & " ==="
  # Use exec (live stdout+stderr) instead of gorgeEx so a SIGSEGV / runtime
  # abort that fires before the buffered output is flushed still surfaces
  # its Nim stack trace to the CI log. gorgeEx captured stdout only and
  # printed it after the binary exited, which loses any backtrace the Nim
  # runtime writes to stderr at crash time.
  exec quoteArg(outputPath)
  echo "=== PASS " & label & " ==="

# Directory names that are pruned at ANY depth during the Nim-file walk. These
# hold no source we format but can contain huge generated trees (cargo `target/`
# under the Rust example + test crates, cmake build dirs, Python venvs) that
# would otherwise blow the NimScript VM iteration budget in `collectNimFiles`.
const nphExcludedDirs = [
  "nimbledeps", "vendor", "doc", "build", ".venv", ".git", "target", "cmake-build",
  "cmake-build-asan", "node_modules", "__pycache__", ".mypy_cache",
]

proc isExcludedNimPath(path: string): bool =
  for part in path.replace('\\', '/').split('/'):
    if part.len > 0 and part != "." and part in nphExcludedDirs:
      return true
  false

proc isNphFile(path: string): bool =
  path.endsWith(".nim") or path.endsWith(".nimble")

proc addUniqueNimFiles(files: var seq[string], output: string) =
  for line in output.splitLines():
    let path = line.strip()
    if path.len > 0 and isNphFile(path) and not isExcludedNimPath(path) and
        path notin files:
      files.add(path)

proc changedNimFiles(): seq[string] =
  for command in [
    "git diff --name-only --diff-filter=ACMR --",
    "git diff --cached --name-only --diff-filter=ACMR --",
    "git ls-files --others --exclude-standard -- '*.nim' '*.nimble'",
  ]:
    let (output, exitCode) = gorgeEx(command)
    if exitCode != 0:
      quit "Unable to determine modified files from git"

    result.addUniqueNimFiles(output)

proc collectNimFiles(dir: string, files: var seq[string]) =
  for kind, path in walkDir(dir, relative = true):
    let fullPath =
      if dir == ".":
        path
      else:
        joinPath(dir, path)
    let normalized = fullPath.replace('\\', '/')
    case kind
    of pcDir:
      if not isExcludedNimPath(normalized):
        collectNimFiles(normalized, files)
    of pcFile, pcLinkToFile:
      if isNphFile(normalized) and not isExcludedNimPath(normalized):
        files.add(normalized)
    else:
      discard

proc allNimFiles(): seq[string] =
  collectNimFiles(".", result)

proc installNphIfNeeded() =
  if findExe("nph").len == 0:
    echo "Installing nph formatter"
    exec "nimble install -y nph"

proc runNph(files: seq[string], emptyMessage: string) =
  installNphIfNeeded()

  if files.len == 0:
    echo emptyMessage
  else:
    for file in files:
      exec "nph " & quoteArg(file)

task fetchVendor, "Initialize/update vendored third-party dependencies (git submodules)":
  ## Fetches the third-party C/C++ dependencies required by the FFI
  ## builds (currently jsoncons under vendor/jsoncons). Safe to run repeatedly.
  if not dirExists(".git"):
    quit "fetchVendor must be run from a git checkout (no .git directory found)."
  exec "git submodule update --init --recursive vendor"

task test, "Run all single and multi-threaded broker tests":
  let tests = [
    "test_event_broker", "test_request_broker", "test_request_broker_sugar",
    "test_request_broker_sync_void", "test_multi_request_broker", "test_signal_broker",
    "test_broker_oop", "test_broker_lifecycle", "test_broker_ctor_shapes",
    "test_broker_interface_signal", "test_handler_sugar",
  ]
  for f in tests:
    for opt in [
      "-d:nimUnittestOutputLevel:VERBOSE --mm:orc",
      "-d:nimUnittestOutputLevel:VERBOSE --mm:refc",
      "-d:nimUnittestOutputLevel:VERBOSE -d:release -d:gcAssert -d:sysAssert --mm:orc",
      "-d:nimUnittestOutputLevel:VERBOSE -d:release -d:gcAssert -d:sysAssert --mm:refc",
    ]:
      test opt, f

  let mtTests = [
    "test_multi_thread_request_broker", "test_multi_thread_event_broker",
    "test_multi_thread_signal_broker", "test_multi_thread_broker_configs",
    "test_mt_large_payload", "test_mt_drop_async_eager", "test_alloc_race_variants",
    "test_multi_thread_handler_sugar",
  ]
  for f in mtTests:
    for opt in [
      "-d:nimUnittestOutputLevel:VERBOSE --mm:orc --threads:on",
      "-d:nimUnittestOutputLevel:VERBOSE --mm:refc --threads:on",
      "-d:nimUnittestOutputLevel:VERBOSE -d:release --mm:orc --threads:on",
      "-d:nimUnittestOutputLevel:VERBOSE -d:release --mm:refc --threads:on",
    ]:
      test opt, f

task testAllocRace,
  "Regression gate: worker-thread teardown UAF reproducer, N trials per variant":
  ## Repeated-run crash harness for the historical win+refc MT-broker UAF
  ## (0xC0000005 at worker-thread exit; see teardownBrokerThread in
  ## brokers/internal/mt_broker_common.nim). Before the teardown-sequence fix
  ## the V1 variant crashed ~30% of runs on GitHub win runners under
  ## refc+release, on every Nim 2.2.x. The gate runs each single-ingredient
  ## variant from test/test_alloc_race_variants.nim solo (own process,
  ## unittest2 positional glob), `trials` times, and fails on ANY crash.
  ##
  ## Piped output (gorgeEx) is intentional — it widens the race window far
  ## beyond what a single console-attached CI run samples.
  const
    varFile = "test_alloc_race_variants"
    varSuite = "alloc-race variants"
    variants = [
      "V1 worker provider, one worker requester",
      "V2 main provider, three concurrent requesters",
      "V3 worker provider, main-thread requester",
      "V4 no provider, one error-path requester",
      "V5 worker provider, worker requester + default-fail requester",
      "V6 full original shape",
    ]
    trials = 40

  proc buildBin(name, opt: string): string =
    result = joinPath("build", "alloc_race_" & name).addFileExt(ExeExt)
    exec "nim c " & opt & " --path:. --out:" & quoteArg(result) & " test/" & varFile &
      ".nim"

  proc runTrials(label, exePath, args: string): int =
    ## Runs the binary `trials` times with `args`, returns crashed-run count.
    for i in 1 .. trials:
      let (outp, code) = gorgeEx(quoteArg(exePath) & args)
      if code != 0:
        inc result
        echo "[" & label & "] trial " & $i & "/" & $trials & ": CRASH (exit code " &
          $code & "), last output lines:"
        let lines = outp.splitLines()
        for l in lines[max(0, lines.len - 8) ..< lines.len]:
          echo "    " & l

  let exe = buildBin(
    "refc_rel", "-d:nimUnittestOutputLevel:VERBOSE -d:release --mm:refc --threads:on"
  )

  var totalCrashes = 0
  for v in variants:
    let crashes = runTrials(v, exe, " " & quoteArg(varSuite & "::" & v))
    totalCrashes += crashes
    echo "TEARDOWN-GATE: " & v & ": " & $crashes & "/" & $trials & " crashed"
  if totalCrashes > 0:
    quit("TEARDOWN-GATE FAILED: " & $totalCrashes & " crashed trials", 1)
  echo "TEARDOWN-GATE PASSED: 0 crashes across " & $(variants.len * trials) & " trials"

task testSugarRejects, "Compile-fail tests: each test/reject/*.nim must NOT compile":
  let rejects = [
    "reject_mismatch", "reject_mixedname", "reject_dupzero", "reject_badret",
    "reject_signal_badmode", "reject_signal_nohandler", "reject_signal_badshape",
    "reject_signal_duphandler", "reject_provideit_fallthrough",
    "reject_provideit_loopend", "reject_provideit_partialif",
    "reject_provideit_voidtrailing", "reject_provideit_multi",
  ]
  for f in rejects:
    let (outp, code) = gorgeEx(
      "nim c --hints:off --path:. --outdir:build/reject test/reject/" & f & ".nim"
    )
    if code == 0:
      echo outp
      quit("REJECT TEST FAILED: " & f & " compiled but must not", 1)
    echo "  reject OK (correctly rejected): " & f
  # API-mode rejects (reduced-A): cross-interface apiName collisions only
  # manifest under -d:BrokerFfiApi --threads:on.
  let apiRejects = ["reject_iface_apicollision"]
  for f in apiRejects:
    let (outp, code) = gorgeEx(
      "nim c --hints:off -d:BrokerFfiApi --threads:on --path:. --outdir:build/reject test/reject/" &
        f & ".nim"
    )
    if code == 0:
      echo outp
      quit("REJECT TEST FAILED: " & f & " compiled but must not", 1)
    echo "  reject OK (correctly rejected): " & f
  echo "all sugar-reject tests passed"

task runFfiBenchEventStress,
  "Build benchlib  + the Part D-4/D-5 event dispatch stress drivers and run them":
  # Build the benchlib shared library into test/ffibench/build/.
  exec "nim c -d:BrokerFfiApi --threads:on --app:lib --path:. " &
    "--outdir:test/ffibench/build --mm:orc " &
    "--nimMainPrefix:benchlib test/ffibench/benchlib.nim"
  # Configure + build the five event-stress drivers via the existing CMake project.
  mkDir("test/ffibench/cmake-build")
  exec "cmake -S test/ffibench -B test/ffibench/cmake-build"
  exec "cmake --build test/ffibench/cmake-build " &
    "--target stress_event_mixed_audience " & "--target stress_event_no_foreign " &
    "--target stress_event_no_nim " & "--target stress_event_shutdown " &
    "--target stress_event_slow_callback"
  # Run each in sequence; non-zero exit propagates through `exec`.
  exec "test/ffibench/build/stress_event_mixed_audience"
  exec "test/ffibench/build/stress_event_no_foreign"
  exec "test/ffibench/build/stress_event_no_nim"
  exec "test/ffibench/build/stress_event_shutdown"
  exec "test/ffibench/build/stress_event_slow_callback"

proc runFfiBenchEventStressAsanFor(mm: string) =
  ## Build benchlib + the Part D-4/D-5 drivers with AddressSanitizer
  ## under the requested memory manager (`orc` or `refc`) and run all
  ## five drivers. The Nim library carries the sanitizer instrumentation
  ## via -fsanitize=address + -d:useMalloc; the CMake project picks up
  ## ASAN via -DASAN=ON. Pass = no driver exits non-zero AND no
  ## sanitizer report aborts the process.
  let buildDir = "test/ffibench/build_asan"
  let cmakeDir = "test/ffibench/cmake-build-asan"
  exec "nim c -d:BrokerFfiApi --threads:on --app:lib --path:. " & "--outdir:" & buildDir &
    " --mm:" & mm & " " & "--nimMainPrefix:benchlib -d:useMalloc " &
    "--passC:-fsanitize=address --passC:-fno-omit-frame-pointer " &
    "--passL:-fsanitize=address --debugger:native " & "test/ffibench/benchlib.nim"
  mkDir(cmakeDir)
  let absBuildDir = thisDir() & "/" & buildDir
  exec "cmake -S test/ffibench -B " & cmakeDir & " -DASAN=ON -DBENCH_DIR=" &
    quoteArg(absBuildDir)
  exec "cmake --build " & cmakeDir & " --target stress_event_mixed_audience " &
    "--target stress_event_no_foreign " & "--target stress_event_no_nim " &
    "--target stress_event_shutdown " & "--target stress_event_slow_callback"
  exec buildDir & "/stress_event_mixed_audience"
  exec buildDir & "/stress_event_no_foreign"
  exec buildDir & "/stress_event_no_nim"
  exec buildDir & "/stress_event_shutdown"
  exec buildDir & "/stress_event_slow_callback"

task runFfiBenchEventStressAsan,
  "Run the Part D-4/D-5 event dispatch stress drivers under AddressSanitizer (orc + refc)":
  runFfiBenchEventStressAsanFor("orc")
  runFfiBenchEventStressAsanFor("refc")

proc buildBenchLibWithMM(mm: string, release: bool) =
  ## Shared helper used by the FFI perftest task. Compiles the
  ## benchlib shared library with the requested memory manager and
  ## build mode into test/ffibench/build/. The C++ driver picks up
  ## whatever lib is sitting there.
  var flags =
    "-d:BrokerFfiApi --threads:on --app:lib --path:. --outdir:test/ffibench/build --mm:" &
    mm & " --nimMainPrefix:benchlib"
  if release:
    flags.add(" -d:release")
  exec "nim c " & flags & " test/ffibench/benchlib.nim"

task perftestFfi, "FFI perftest from C++ (5×500×512B; orc + refc × debug + release)":
  ## Companion to `nimble perftest` on the FFI side. Mirrors the same
  ## 5 × 500 × 512 B shape via test/ffibench/perf_driver.cpp so the
  ## numbers line up directly against the Nim-direct baseline printed
  ## by perf_test_multi_thread_*_broker.nim.
  mkDir("test/ffibench/cmake-build")
  for mm in memoryManagerMatrix():
    for releaseTag in ["debug", "release"]:
      let release = releaseTag == "release"
      echo "\n=== perftestFfi: --mm:" & mm & " (" & releaseTag & ") ==="
      buildBenchLibWithMM(mm, release)
      # Reconfigure cmake — the cached lib has the same mtime if mm
      # toggled, so re-invoking cmake -B ensures the linker sees the
      # fresh dylib mtime via the regenerated build.ninja.
      exec "cmake -S test/ffibench -B test/ffibench/cmake-build " &
        (if release: "-DCMAKE_BUILD_TYPE=Release" else: "")
      exec "cmake --build test/ffibench/cmake-build --target perf_driver"
      exec "test/ffibench/build/perf_driver"

task perftestInproc,
  "In-proc Nim request baselines — single-thread + multi-thread vecRequest (5×500×512B; orc + refc × debug + release)":
  ## Layered companion to `perftestFfi`. Same 5 × 500 × 512 B shape, but the
  ## traffic stays in-process: ST = single-thread dispatch floor, MT =
  ## cross-thread channel hop. Stack the boxes against the FFI request path
  ## (CBOR + FFI ABI on top of the MT cost) to attribute where the time goes.
  for mm in memoryManagerMatrix():
    for releaseTag in ["debug", "release"]:
      let release = releaseTag == "release"
      echo "\n=== perftestInproc: --mm:" & mm & " (" & releaseTag & ") ==="
      var flags = "--threads:on --path:. --outdir:build --mm:" & mm
      if release:
        flags.add(" -d:release")
      exec "nim c -r " & flags & " test/ffibench/perf_inproc.nim"

task perfOverhead,
  "Same-thread RequestBroker dispatch overhead vs direct proc call + memory (sync/async, scalar+512B; orc + refc, release)":
  ## Isolates the broker machinery cost: each row calls one shared impl, so
  ## the only variable is the dispatch path (direct / sync broker / async
  ## broker). Reports ns/call overhead vs the matching direct-call floor,
  ## per-call allocation churn, and the static footprint of a registered
  ## broker. Churn is mm-specific (refc shows garbage/call; ORC reclaims
  ## inline ≈ 0), so the matrix is orc + refc, release only.
  for mm in memoryManagerMatrix():
    echo "\n=== perfOverhead: --mm:" & mm & " (release) ==="
    exec "nim c -r -d:release --path:. --outdir:build --mm:" & mm &
      " test/ffibench/perf_overhead.nim"

task perfPhases,
  "Phase-timed MT RequestBroker round-trip: inbound/handler/outbound wake legs + same-thread floor (orc + refc, release)":
  ## Splits one cross-thread request into inbound (requester→provider wake),
  ## handler (provider body), and outbound (provider→requester wake) using a
  ## shared monotonic epoch. Same-thread row is the dispatch floor. Proves
  ## where the ~110 µs round-trip actually goes.
  for mm in memoryManagerMatrix():
    echo "\n=== perfPhases: --mm:" & mm & " (release) ==="
    exec "nim c -r -d:release --threads:on --path:. --outdir:build --mm:" & mm &
      " test/ffibench/perf_phases.nim"

task runFfiBenchEvent, "Build benchlib (release/orc) + bench_event_driver and run it":
  ## Part D-6 — captures the per-emit cost across four scenarios:
  ##   (a) no foreign subs, no nim listeners — atomic-counter fast path
  ##   (b) 1 foreign subscriber             — full courier path
  ##   (c) M foreign subscribers            — encode-amortize-fanout
  ##   (d) K same-thread Nim listeners      — Lane 1 cost in isolation
  ## Output is CSV on stdout; numbers are captured in doc/bench_baseline.md.
  exec "nim c -d:release -d:BrokerFfiApi --threads:on --app:lib --path:. " &
    "--outdir:test/ffibench/build --mm:orc " &
    "--nimMainPrefix:benchlib test/ffibench/benchlib.nim"
  mkDir("test/ffibench/cmake-build")
  exec "cmake -S test/ffibench -B test/ffibench/cmake-build " &
    "-DCMAKE_BUILD_TYPE=Release"
  exec "cmake --build test/ffibench/cmake-build --target bench_event_driver"
  exec "test/ffibench/build/bench_event_driver"

task perftest, "Run performance and stress tests":
  let mtTests = [
    "perf_test_multi_thread_request_broker", "perf_test_multi_thread_event_broker",
    "perf_test_multi_thread_signal_broker",
  ]
  for f in mtTests:
    for opt in [
      "-d:nimUnittestOutputLevel:VERBOSE --mm:orc --threads:on",
      "-d:nimUnittestOutputLevel:VERBOSE --mm:refc --threads:on",
      "-d:nimUnittestOutputLevel:VERBOSE -d:release --mm:orc --threads:on",
      "-d:nimUnittestOutputLevel:VERBOSE -d:release --mm:refc --threads:on",
    ]:
      test opt, f

task testApi, "Run codec unit tests + library init integration tests":
  # Codec round-trip tests + event-courier drop evidence (no FFI flags needed).
  let codecTests =
    ["test_api_codec", "test_api_table_codec", "test_api_event_drop_under_overload"]
  for f in codecTests:
    for opt in [
      "-d:nimUnittestOutputLevel:VERBOSE --mm:orc",
      "-d:nimUnittestOutputLevel:VERBOSE --mm:refc",
      "-d:nimUnittestOutputLevel:VERBOSE -d:release --mm:orc",
      "-d:nimUnittestOutputLevel:VERBOSE -d:release --mm:refc",
    ]:
      test opt, f

  # Library-init integration tests need the FFI runtime.
  # Each test uses a different --nimMainPrefix to keep their generated
  # NimMain symbols distinct.
  let apiTests = [
    ("test_api_library_init", "apitest"),
    ("test_api_callAsync", "acbtest"),
    ("test_api_signal_broker", "sigtest"),
    ("test_api_event_teardown_isolation", "cbevt"),
    ("test_api_discovery", "apidisc"),
    ("test_broker_interface_api", "brokerifaceapi"),
    ("test_broker_interface_mt", "brokerifacemt"),
    ("typemappingtestlib/test_typemappingtestlib", "typemappingtestlib"),
  ]
  for (f, prefix) in apiTests:
    for opt in [
      "-d:nimUnittestOutputLevel:VERBOSE -d:BrokerFfiApi --mm:orc --threads:on",
      "-d:nimUnittestOutputLevel:VERBOSE -d:BrokerFfiApi --mm:refc --threads:on",
      "-d:nimUnittestOutputLevel:VERBOSE -d:BrokerFfiApi -d:release --mm:orc --threads:on",
      "-d:nimUnittestOutputLevel:VERBOSE -d:BrokerFfiApi -d:release --mm:refc --threads:on",
    ]:
      let extraOpt = nimMainPrefixFlag(prefix)
      test opt & extraOpt, f

proc findCargoExe(): string =
  ## Returns the cargo invocation token. Resolving the symlink (rustup
  ## multi-call binary on most installs) loses the dispatch hint, so we
  ## return the bare name and rely on PATH lookup at exec time.
  if findExe("cargo").len == 0:
    quit "Cargo (Rust toolchain) not found. Install rustup or add cargo to PATH."
  result = "cargo"

task runFfiExampleRust,
  "Build the FFI example library + Rust crate and run the Rust example (orc + refc)":
  for mm in memoryManagerMatrix():
    echo "\n=== runFfiExampleRust: --mm:" & mm & " ==="
    setMM(mm)
    buildFfiExampleLibrary(generateRust = true)
    exec quoteArg(findCargoExe()) &
      " run --manifest-path examples/ffiapi/rust_example/Cargo.toml"

proc findGoExe(): string =
  ## Returns the `go` toolchain invocation token. Like cargo via rustup,
  ## we rely on PATH lookup at exec time so the user's installed Go is used.
  if findExe("go").len == 0:
    quit "Go toolchain not found. Install Go 1.21+ or add `go` to PATH."
  result = "go"

proc writeFfiGoModFor(buildDir: string) =
  ## The generated Go module is emitted into either `nimlib/build/mylib_go`
  ## or `nimlib/build/mylib_go`. Go can't conditionally pick a
  ## `replace` target by build tag, so we rewrite the example's go.mod
  ## per mode before invoking the Go toolchain.
  let modPath = "examples/ffiapi/go_example/go.mod"
  var contents = "// Generated by nim-brokers test harness — do not edit.\n"
  contents.add("module github.com/status-im/nim-brokers/examples/ffiapi/go_example\n\n")
  contents.add("go 1.21\n\n")
  contents.add("require mylib v0.0.0\n")
  if buildDir == "build":
    contents.add("require github.com/fxamacker/cbor/v2 v2.7.0\n")
  contents.add("\nreplace mylib => ../nimlib/" & buildDir & "/mylib_go\n")
  writeFile(modPath, contents)
  # Sync go.sum + transitive deps for the cbor case.
  if buildDir == "build":
    withDir "examples/ffiapi/go_example":
      exec quoteArg(findGoExe()) & " mod tidy"

task buildFfiExampleGo, "Build the FFI API example library  + generated Go wrapper":
  buildFfiExampleLibrary(generateGo = true)

task runFfiExampleGo,
  "Build the FFI API example library + run the Go example (orc + refc)":
  for mm in memoryManagerMatrix():
    echo "\n=== runFfiExampleGo: --mm:" & mm & " ==="
    setMM(mm)
    buildFfiExampleLibrary(generateGo = true)
    writeFfiGoModFor("build")
    withDir "examples/ffiapi/go_example":
      exec quoteArg(findGoExe()) & " run ."

# ---------------------------------------------------------------------------
# FFI build of mylib.nim + the same cpp_example/main.cpp.
# ---------------------------------------------------------------------------

task buildFfiExample, "Build FFI API example library (into nimlib/build)":
  buildFfiExampleLibrary()

task buildFfiExampleCpp,
  "Build FFI API example — C++ application against the library (via CMake)":
  buildFfiExampleLibrary()
  buildFfiCmakeTarget("example_cpp")

task runFfiExampleCpp,
  "Build and run the C++ FFI example application against the library (orc + refc)":
  for mm in memoryManagerMatrix():
    echo "\n=== runFfiExampleCpp: --mm:" & mm & " ==="
    setMM(mm)
    buildFfiExampleLibrary()
    buildFfiCmakeTarget("example_cpp")
    exec quoteArg(ffiExampleExecutablePath("examples/ffiapi/cpp_example"))

task runFfiExamplePy,
  "Build the FFI example library + Python wrapper and run python_example/main.py (orc + refc)":
  for mm in memoryManagerMatrix():
    echo "\n=== runFfiExamplePy: --mm:" & mm & " ==="
    setMM(mm)
    buildFfiExampleLibrary(true)
    putEnv("MYLIB_BUILD_DIR", "build")
    exec quoteArg(findPythonExe()) & " " &
      quoteArg("examples/ffiapi/python_example/main.py")

# ---------------------------------------------------------------------------
# hierlib — the OOP interface-model FFI example (BrokerInterface(API) +
# BrokerImplement + bindToContext). Same C ABI as the flat mylib example.
# ---------------------------------------------------------------------------

proc buildHierExampleLibrary(
    generatePy = false, generateRust = false, generateGo = false
) =
  var flags =
    "-d:BrokerFfiApi --threads:on --app:lib --path:. " &
    "--outdir:examples/ffiapi/hierlib/nimlib/build"
  flags.add(nimMainPrefixFlag("hierlib"))
  flags.add(nimWindowsCcFlag())
  flags.add(nimWindowsImplibFlag("examples/ffiapi/hierlib/nimlib/build", "hierlib"))
  if existsEnv("MM"):
    flags.add(" --mm:" & getEnv("MM"))
  else:
    flags.add(" --mm:orc")
  if generatePy or existsEnv("GEN_PY"):
    flags.add(" -d:BrokerFfiApiGenPy")
  if generateRust or existsEnv("GEN_RUST"):
    flags.add(" -d:BrokerFfiApiGenRust")
  if generateGo or existsEnv("GEN_GO"):
    flags.add(" -d:BrokerFfiApiGenGo")
  exec "nim c " & flags & " examples/ffiapi/hierlib/nimlib/hierlib.nim"

proc buildHierCmakeTarget(target = "") =
  let cmakeDir = "examples/ffiapi/hierlib"
  let buildDir = cmakeDir & "/cmake-build"
  mkDir(buildDir)
  exec "cmake -S " & cmakeDir & " -B " & buildDir & cmakeWindowsConfigureExtras()
  if target.len == 0:
    exec "cmake --build " & buildDir
  else:
    exec "cmake --build " & buildDir & " --target " & target

task buildHierExample, "Build the hierlib interface-model FFI example library":
  buildHierExampleLibrary()

task runHierExampleCpp, "Build hierlib + the C++ example and run it (orc + refc)":
  for mm in memoryManagerMatrix():
    echo "\n=== runHierExampleCpp: --mm:" & mm & " ==="
    setMM(mm)
    buildHierExampleLibrary()
    buildHierCmakeTarget("hier_cpp")
    exec quoteArg(ffiExampleExecutablePath("examples/ffiapi/hierlib/cpp_example"))

task runHierExampleRust,
  "Build hierlib + Rust crate and run the Rust example (orc + refc)":
  for mm in memoryManagerMatrix():
    echo "\n=== runHierExampleRust: --mm:" & mm & " ==="
    setMM(mm)
    buildHierExampleLibrary(generateRust = true)
    exec quoteArg(findCargoExe()) &
      " run --manifest-path examples/ffiapi/hierlib/rust_example/Cargo.toml"

task runHierExampleGo, "Build hierlib + Go module and run the Go example (orc + refc)":
  for mm in memoryManagerMatrix():
    echo "\n=== runHierExampleGo: --mm:" & mm & " ==="
    setMM(mm)
    buildHierExampleLibrary(generateGo = true)
    withDir "examples/ffiapi/hierlib/go_example":
      exec quoteArg(findGoExe()) & " mod tidy"
      exec quoteArg(findGoExe()) & " run ."

# Persistence example: two-layer interfaces (IPersistence -> IBackend) with a
# factory selecting File/Memory backends, requests + events at both levels, and
# per-instance routing. The entry module is IPersistenceLib.nim but the
# registered library name (and generated header/dylib) is "persistence", so the
# dylib output name is forced to lib<persistence> here.
proc persistenceLibOutFlag(): string =
  let dir = "examples/persistence/nimlib/build"
  when defined(windows):
    " --out:" & (dir / "persistence.dll")
  elif defined(macosx):
    " --out:" & (dir / "libpersistence.dylib")
  else:
    " --out:" & (dir / "libpersistence.so")

proc buildPersistenceExampleLibrary(
    generatePy = false, generateRust = false, generateGo = false
) =
  var flags =
    "-d:BrokerFfiApi --threads:on --app:lib --path:. " &
    "--outdir:examples/persistence/nimlib/build"
  flags.add(nimMainPrefixFlag("persistence"))
  flags.add(nimWindowsCcFlag())
  flags.add(nimWindowsImplibFlag("examples/persistence/nimlib/build", "persistence"))
  if existsEnv("MM"):
    flags.add(" --mm:" & getEnv("MM"))
  else:
    flags.add(" --mm:orc")
  if existsEnv("SRCGEN"):
    flags.add(" -d:brokerDebug")
  if generatePy or existsEnv("GEN_PY"):
    flags.add(" -d:BrokerFfiApiGenPy")
  if generateRust or existsEnv("GEN_RUST"):
    flags.add(" -d:BrokerFfiApiGenRust")
  if generateGo or existsEnv("GEN_GO"):
    flags.add(" -d:BrokerFfiApiGenGo")
  flags.add(persistenceLibOutFlag())
  exec "nim c " & flags & " examples/persistence/nimlib/IPersistenceLib.nim"

proc buildPersistenceCmakeTarget(target = "") =
  let cmakeDir = "examples/persistence"
  let buildDir = cmakeDir & "/cmake-build"
  mkDir(buildDir)
  exec "cmake -S " & cmakeDir & " -B " & buildDir & cmakeWindowsConfigureExtras()
  if target.len == 0:
    exec "cmake --build " & buildDir
  else:
    exec "cmake --build " & buildDir & " --target " & target

task buildPersistenceExample,
  "Build the persistence interface-model FFI example library":
  buildPersistenceExampleLibrary()

task runPersistenceExampleCpp,
  "Build persistence + the C++ example and run it (orc + refc)":
  for mm in memoryManagerMatrix():
    echo "\n=== runPersistenceExampleCpp: --mm:" & mm & " ==="
    setMM(mm)
    buildPersistenceExampleLibrary()
    buildPersistenceCmakeTarget("persistence_cpp")
    exec quoteArg(ffiExampleExecutablePath("examples/persistence/cpp_example"))

task runPersistenceExamplePy,
  "Build persistence + Python wrapper and run persistence/python_example/main.py (orc + refc)":
  for mm in memoryManagerMatrix():
    echo "\n=== runPersistenceExamplePy: --mm:" & mm & " ==="
    setMM(mm)
    buildPersistenceExampleLibrary(generatePy = true)
    exec quoteArg(findPythonExe()) & " " &
      quoteArg("examples/persistence/python_example/main.py")

task runPersistenceExampleRust,
  "Build persistence + Rust crate and run the Rust example (orc + refc)":
  for mm in memoryManagerMatrix():
    echo "\n=== runPersistenceExampleRust: --mm:" & mm & " ==="
    setMM(mm)
    buildPersistenceExampleLibrary(generateRust = true)
    exec quoteArg(findCargoExe()) &
      " run --manifest-path examples/persistence/rust_example/Cargo.toml"

task runPersistenceExampleGo,
  "Build persistence + Go wrapper and run the Go example (orc + refc)":
  for mm in memoryManagerMatrix():
    echo "\n=== runPersistenceExampleGo: --mm:" & mm & " ==="
    setMM(mm)
    buildPersistenceExampleLibrary(generateGo = true)
    withDir "examples/persistence/go_example":
      exec quoteArg(findGoExe()) & " mod tidy"
      exec quoteArg(findGoExe()) & " run ."

task runPersistenceExampleNim, "Build and run the pure-Nim persistence example":
  let mm =
    if existsEnv("MM"):
      getEnv("MM")
    else:
      "orc"
  var flags = "--threads:on --path:. --outdir:build --mm:" & mm

  if existsEnv("SRCGEN"):
    flags.add(" -d:brokerDebug")

  exec "nim c -r " & flags & " examples/persistence/nim_example/main.nim"

task runHierExamplePy,
  "Build hierlib + Python wrapper and run hierlib/python_example/main.py (orc + refc)":
  for mm in memoryManagerMatrix():
    echo "\n=== runHierExamplePy: --mm:" & mm & " ==="
    setMM(mm)
    buildHierExampleLibrary(true)
    exec quoteArg(findPythonExe()) & " " &
      quoteArg("examples/ffiapi/hierlib/python_example/main.py")

# FFI build of the typemapping test library: compiles
# test/typemappingtestlib/typemappingtestlib.nim with -d:BrokerFfiApi
# into build/ and drives test_typemappingtestlib.{cpp,py} against
# that build.
proc buildTypeMapTestLib(
    genPy: bool = false, genRust: bool = false, genGo: bool = false
) =
  let mm =
    if existsEnv("MM"):
      getEnv("MM")
    else:
      "orc"
  let release = existsEnv("RELEASE")
  var flags =
    "-d:BrokerFfiApi --threads:on --app:lib --mm:" & mm &
    " --path:. --outdir:test/typemappingtestlib/build"
  flags.add(nimMainPrefixFlag("typemappingtestlib"))
  flags.add(nimWindowsCcFlag())
  flags.add(nimWindowsImplibFlag("test/typemappingtestlib/build", "typemappingtestlib"))
  if release:
    flags.add(" -d:release")
  if genPy:
    flags.add(" -d:BrokerFfiApiGenPy")
  if genRust or existsEnv("GEN_RUST"):
    flags.add(" -d:BrokerFfiApiGenRust")
  if genGo or existsEnv("GEN_GO"):
    flags.add(" -d:BrokerFfiApiGenGo")
  exec "nim c " & flags & " test/typemappingtestlib/typemappingtestlib.nim"

task buildTypeMapTestLib, "Build the type-mapping parity test library":
  buildTypeMapTestLib()

proc typeMapTestLibCmakeDir(): string =
  "test/typemappingtestlib/cmake-build"

task runTypeMapTestLibCpp,
  "Build the parity library + run the C++ parity test against it (orc + refc)":
  for mm in memoryManagerMatrix():
    echo "\n=== runTypeMapTestLibCpp: --mm:" & mm & " ==="
    setMM(mm)
    buildTypeMapTestLib()
    let cmakeDir = typeMapTestLibCmakeDir()
    let srcDir = "test/typemappingtestlib"
    exec "cmake -S " & quoteArg(srcDir) & " -B " & quoteArg(cmakeDir) &
      cmakeWindowsConfigureExtras()
    exec "cmake --build " & quoteArg(cmakeDir)
    exec quoteArg("test/typemappingtestlib/build/test_typemappingtestlib")

task runTypeMapTestLibRust,
  "Build the parity library + Rust wrapper and run the Rust parity test (orc + refc)":
  for mm in memoryManagerMatrix():
    echo "\n=== runTypeMapTestLibRust: --mm:" & mm & " ==="
    setMM(mm)
    buildTypeMapTestLib(genRust = true)
    exec quoteArg(findCargoExe()) &
      " run --manifest-path test/typemappingtestlib/rust_test/Cargo.toml"

proc writeTypeMapGoModFor(buildDir: string) =
  let modPath = "test/typemappingtestlib/go_test/go.mod"
  var contents = "// Generated by nim-brokers test harness — do not edit.\n"
  contents.add(
    "module github.com/status-im/nim-brokers/test/typemappingtestlib/go_test\n\n"
  )
  contents.add("go 1.21\n\n")
  contents.add("require typemappingtestlib v0.0.0\n")
  if buildDir == "build":
    contents.add("require github.com/fxamacker/cbor/v2 v2.7.0\n")
  contents.add(
    "\nreplace typemappingtestlib => ../" & buildDir & "/typemappingtestlib_go\n"
  )
  writeFile(modPath, contents)
  if buildDir == "build":
    withDir "test/typemappingtestlib/go_test":
      exec quoteArg(findGoExe()) & " mod tidy"

task runTypeMapTestLibGo,
  "Build the parity library + Go wrapper and run the Go parity test (orc + refc)":
  for mm in memoryManagerMatrix():
    echo "\n=== runTypeMapTestLibGo: --mm:" & mm & " ==="
    setMM(mm)
    buildTypeMapTestLib(genGo = true)
    writeTypeMapGoModFor("build")
    withDir "test/typemappingtestlib/go_test":
      exec quoteArg(findGoExe()) & " run ."

task runTypeMapTestLibPy,
  "Build the parity library + Python wrapper and run the Python parity test (orc + refc)":
  for mm in memoryManagerMatrix():
    echo "\n=== runTypeMapTestLibPy: --mm:" & mm & " ==="
    setMM(mm)
    buildTypeMapTestLib(true)
    # The test_typemappingtestlib.py driver runs against the FFI
    # build; selection is via TYPEMAP_BUILD_DIR which points at the
    # build output that holds the matching generated .py wrapper.
    putEnv("TYPEMAP_BUILD_DIR", "build")
    exec quoteArg(findPythonExe()) & " " &
      quoteArg("test/typemappingtestlib/test_typemappingtestlib.py")

# ---------------------------------------------------------------------------
# Sanitizer support — ASan(+UBSan), ASan+LSan(+UBSan) on Linux, and TSan.
# ---------------------------------------------------------------------------
# Modes (the `mode` string threaded through the helpers below):
#   "asan"     — AddressSanitizer + UndefinedBehaviorSanitizer. detect_leaks=0.
#                Cross-platform (macOS/Linux/Windows).
#   "asanleak" — asan + LeakSanitizer (detect_leaks=1). LSan is Linux-only; on
#                macOS/Windows this degrades to plain ASan+UBSan (with a notice),
#                since LSan is unsupported there.
#   "tsan"     — ThreadSanitizer. Mutually exclusive with ASan, so it is always a
#                SEPARATE build. Built with `--tlsEmulation:off` so TSan observes
#                real TLS accesses (the MT brokers lean heavily on threadvars:
#                gBrokerThreadSignal, mtThreadIdMarker, the per-thread pollers).
#
# UBSan is folded into the asan modes (same build, near-zero cost). `function`
# and `vptr` checks are disabled: the FFI C ABI casts cdecl callback pointers
# (trips -fsanitize=function) and carries no C++ RTTI (vptr). Everything else —
# alignment, signed-overflow, null deref, bad enum/bool, shift UB — stays on.

proc sanitizerSuppPath(name: string): string =
  thisDir() / "tools" / "sanitizers" / name

proc sanitizerCompileFlags(mode: string): string =
  case mode
  of "tsan":
    result = "-fsanitize=thread -fno-omit-frame-pointer -g"
  else: # asan / asanleak
    result =
      "-fsanitize=address -fsanitize=undefined " &
      "-fno-sanitize=function,vptr -fno-omit-frame-pointer -g"
    when defined(windows):
      # Windows ASAN symbolizes via PDB (CodeView), not DWARF.
      result.add(" -gcodeview")

proc sanitizerLinkFlags(mode: string, sharedLib: bool = false): string =
  case mode
  of "tsan":
    result = "-fsanitize=thread -g"
    when defined(linux):
      if sharedLib:
        result.add(" -shared-libtsan")
  else: # asan / asanleak
    result = "-fsanitize=address -fsanitize=undefined -g"
    when defined(linux):
      # The Nim .so links the shared sanitizer runtime; a foreign exe linked
      # with the static runtime otherwise can't satisfy the .so's dep.
      if sharedLib:
        result.add(" -shared-libasan")
    when defined(windows):
      # Tell lld to emit a PDB so ASAN frames carry function/line info.
      result.add(" -Wl,/debug")

proc linuxSharedRuntimeOnPath(printName: string) =
  ## Put the directory holding the named clang_rt shared runtime on
  ## LD_LIBRARY_PATH so a Nim .so linked with the *shared* sanitizer runtime
  ## loads cleanly. No-op if clang can't resolve it (static-runtime build).
  when defined(linux):
    let (so, rc) = gorgeEx("clang -print-file-name=" & printName)
    let trimmed = so.strip()
    if rc == 0 and trimmed.len > 0 and trimmed != printName:
      let dir = parentDir(trimmed)
      let cur = getEnv("LD_LIBRARY_PATH")
      putEnv(
        "LD_LIBRARY_PATH",
        if cur.len == 0:
          dir
        else:
          dir & ":" & cur,
      )

proc setSanitizerEnv(mode: string) =
  putEnv("MallocNanoZone", "0")
  if not existsEnv("ASAN_SYMBOLIZER_PATH"):
    let llvmSym = findExe("llvm-symbolizer")
    if llvmSym.len > 0:
      putEnv("ASAN_SYMBOLIZER_PATH", llvmSym)
  case mode
  of "tsan":
    var opts =
      "symbolize=1:halt_on_error=1:second_deadlock_stack=1:history_size=4:exitcode=66"
    let supp = sanitizerSuppPath("tsan.supp")
    if fileExists(supp):
      # Single-quote the path: the sanitizer flag parser splits on ':', so an
      # unquoted Windows drive letter ("D:\...") aborts the runtime with
      # "expected '=' in TSAN_OPTIONS". Quotes are accepted on POSIX too.
      opts.add(":suppressions='" & supp & "'")
    putEnv("TSAN_OPTIONS", opts)
    linuxSharedRuntimeOnPath("libclang_rt.tsan-x86_64.so")
  else: # asan / asanleak
    var leaks = mode == "asanleak"
    when not defined(linux):
      if leaks:
        echo "note: LeakSanitizer is Linux-only; running plain ASan+UBSan here"
      leaks = false
    let detect = if leaks: "detect_leaks=1" else: "detect_leaks=0"
    putEnv(
      "ASAN_OPTIONS",
      detect &
        ":symbolize=1:print_stacktrace=1:halt_on_error=1:abort_on_error=0:strict_string_checks=1",
    )
    var ubopts = "print_stacktrace=1:halt_on_error=1"
    let usupp = sanitizerSuppPath("ubsan.supp")
    if fileExists(usupp):
      # Single-quoted for the same Windows drive-letter reason as tsan above —
      # this unquoted path is what failed every Windows Sanitizer CI cell with
      # "AddressSanitizer: ERROR: expected '=' in UBSAN_OPTIONS".
      ubopts.add(":suppressions='" & usupp & "'")
    putEnv("UBSAN_OPTIONS", ubopts)
    if leaks:
      let lsupp = sanitizerSuppPath("lsan.supp")
      if fileExists(lsupp):
        putEnv("LSAN_OPTIONS", "suppressions='" & lsupp & "'")
    linuxSharedRuntimeOnPath("libclang_rt.asan-x86_64.so")

# Back-compat shims (pre-existing call sites + external dispatch references).
proc setAsanEnv() =
  setSanitizerEnv("asan")

proc asanCompileFlags(): string =
  sanitizerCompileFlags("asan")

proc asanLinkFlags(sharedLib: bool = false): string =
  sanitizerLinkFlags("asan", sharedLib)

proc testSan(mode, mm, path: string, extra = "") =
  ## Build `test/<path>.nim` under the requested sanitizer `mode` + memory
  ## manager and run it. `extra` carries per-test compile flags (e.g. the FFI
  ## `-d:BrokerFfiApi --nimMainPrefix:<x>` set).
  let outputPath = joinPath("build", path & "_" & mode & "_" & mm).addFileExt(ExeExt)
  let label = path & " [" & mode & ", clang, mm:" & mm & ", debug]"
  # -d:noSignalHandler: disable Nim's SIGSEGV handler so the sanitizer's own
  # handler fires on faults. Without it, Nim prints a traceback and exits
  # before the sanitizer can report the underlying error.
  # -d:useMalloc routes Nim's heaps (incl. the shared heap backing the FFI
  # registry/courier buffers) through the system allocator so the sanitizer
  # actually sees those allocations. For TSan it is REQUIRED: Nim's native
  # MemRegion allocator shares internal free-list metadata across threads in a
  # way TSan can't see, producing false-positive races on alloc/dealloc.
  var flags =
    "--cc:clang --debugger:native -d:nimUnittestOutputLevel:VERBOSE " &
    "-d:noSignalHandler -d:useMalloc --threads:on --mm:" & mm
  if mode == "tsan":
    flags.add(" --tlsEmulation:off")
  flags.add(
    " --passC:" & quoteArg(sanitizerCompileFlags(mode)) & " --passL:" &
      quoteArg(sanitizerLinkFlags(mode)) & " --path:. --out:" & quoteArg(outputPath)
  )
  if extra.len > 0:
    flags.add(" " & extra)
  exec "nim c " & flags & " test/" & path & ".nim"
  setSanitizerEnv(mode)
  echo "=== RUN  " & label & " ==="
  exec quoteArg(outputPath)
  echo "=== PASS " & label & " ==="

proc testAsan(mm: string, path: string) =
  testSan("asan", mm, path)

task testMtEventBrokerAsanOrc,
  "Run multi-thread event broker tests under AddressSanitizer (clang, orc, debug)":
  testAsan("orc", "test_multi_thread_event_broker")

task testMtEventBrokerAsanRefc,
  "Run multi-thread event broker tests under AddressSanitizer (clang, refc, debug)":
  testAsan("refc", "test_multi_thread_event_broker")

task testMtRequestBrokerAsanOrc,
  "Run multi-thread request broker tests under AddressSanitizer (clang, orc, debug)":
  testAsan("orc", "test_multi_thread_request_broker")

task testMtRequestBrokerAsanRefc,
  "Run multi-thread request broker tests under AddressSanitizer (clang, refc, debug)":
  testAsan("refc", "test_multi_thread_request_broker")

task testMtBrokerConfigsAsanOrc,
  "Run multi-thread broker config showcase under AddressSanitizer (clang, orc, debug)":
  testAsan("orc", "test_multi_thread_broker_configs")

task testMtBrokerConfigsAsanRefc,
  "Run multi-thread broker config showcase under AddressSanitizer (clang, refc, debug)":
  testAsan("refc", "test_multi_thread_broker_configs")

task testMtSignalBrokerAsanOrc,
  "Run multi-thread signal broker tests under AddressSanitizer (clang, orc, debug)":
  testAsan("orc", "test_multi_thread_signal_broker")

task testMtSignalBrokerAsanRefc,
  "Run multi-thread signal broker tests under AddressSanitizer (clang, refc, debug)":
  testAsan("refc", "test_multi_thread_signal_broker")

# ---------------------------------------------------------------------------
# ThreadSanitizer variants of the multi-thread broker tests. TSan is the
# most relevant sanitizer for these: it validates the Channel[T] / shared
# ThreadSignalPtr / Lock-protected bucket registry / Atomic happens-before
# the MT (and FFI) lanes rely on.
# ---------------------------------------------------------------------------
task testMtEventBrokerTsanOrc,
  "Run multi-thread event broker tests under ThreadSanitizer (clang, orc, debug)":
  testSan("tsan", "orc", "test_multi_thread_event_broker")

task testMtEventBrokerTsanRefc,
  "Run multi-thread event broker tests under ThreadSanitizer (clang, refc, debug)":
  testSan("tsan", "refc", "test_multi_thread_event_broker")

task testMtRequestBrokerTsanOrc,
  "Run multi-thread request broker tests under ThreadSanitizer (clang, orc, debug)":
  testSan("tsan", "orc", "test_multi_thread_request_broker")

task testMtRequestBrokerTsanRefc,
  "Run multi-thread request broker tests under ThreadSanitizer (clang, refc, debug)":
  testSan("tsan", "refc", "test_multi_thread_request_broker")

task testMtBrokerConfigsTsanOrc,
  "Run multi-thread broker config showcase under ThreadSanitizer (clang, orc, debug)":
  testSan("tsan", "orc", "test_multi_thread_broker_configs")

task testMtBrokerConfigsTsanRefc,
  "Run multi-thread broker config showcase under ThreadSanitizer (clang, refc, debug)":
  testSan("tsan", "refc", "test_multi_thread_broker_configs")

task testMtSignalBrokerTsanOrc,
  "Run multi-thread signal broker tests under ThreadSanitizer (clang, orc, debug)":
  testSan("tsan", "orc", "test_multi_thread_signal_broker")

task testMtSignalBrokerTsanRefc,
  "Run multi-thread signal broker tests under ThreadSanitizer (clang, refc, debug)":
  testSan("tsan", "refc", "test_multi_thread_signal_broker")

# ---------------------------------------------------------------------------
# Sanitizer coverage for the FFI event-teardown isolation regression test
# (the cross-context subs-count fix). FFI build needs -d:BrokerFfiApi and a
# distinct --nimMainPrefix.
# ---------------------------------------------------------------------------
const teardownTestExtra = "-d:BrokerFfiApi --nimMainPrefix:cbevt"

task testApiTeardownAsanOrc,
  "Run FFI event-teardown isolation test under ASan+UBSan (clang, orc, debug)":
  testSan("asan", "orc", "test_api_event_teardown_isolation", teardownTestExtra)

task testApiTeardownAsanRefc,
  "Run FFI event-teardown isolation test under ASan+UBSan (clang, refc, debug)":
  testSan("asan", "refc", "test_api_event_teardown_isolation", teardownTestExtra)

const signalApiTestExtra = "-d:BrokerFfiApi --nimMainPrefix:sigtest"

task testApiSignalAsanOrc,
  "Run FFI SignalBroker(API) slot-free _call test under ASan+UBSan (clang, orc, debug)":
  testSan("asan", "orc", "test_api_signal_broker", signalApiTestExtra)

task testApiSignalAsanRefc,
  "Run FFI SignalBroker(API) slot-free _call test under ASan+UBSan (clang, refc, debug)":
  testSan("asan", "refc", "test_api_signal_broker", signalApiTestExtra)

task testApiSignalTsanOrc,
  "Run FFI SignalBroker(API) slot-free _call test under ThreadSanitizer (clang, orc, debug)":
  testSan("tsan", "orc", "test_api_signal_broker", signalApiTestExtra)

task testApiSignalTsanRefc,
  "Run FFI SignalBroker(API) slot-free _call test under ThreadSanitizer (clang, refc, debug)":
  testSan("tsan", "refc", "test_api_signal_broker", signalApiTestExtra)

task testApiTeardownTsanOrc,
  "Run FFI event-teardown isolation test under ThreadSanitizer (clang, orc, debug)":
  testSan("tsan", "orc", "test_api_event_teardown_isolation", teardownTestExtra)

task testApiTeardownTsanRefc,
  "Run FFI event-teardown isolation test under ThreadSanitizer (clang, refc, debug)":
  testSan("tsan", "refc", "test_api_event_teardown_isolation", teardownTestExtra)

# ---------------------------------------------------------------------------
# Persistence C++ example under sanitizers — builds the Nim library AND the
# C++ consumer with matching instrumentation, then runs the consumer.
# `mode` ∈ {asan, asanleak, tsan}. Driven across orc+refc by the tasks below.
# ---------------------------------------------------------------------------
proc runSanitizedPersistenceCpp(mode, mm: string) =
  let libBuild = "examples/persistence/nimlib/build"
  let cmakeDir = "examples/persistence"
  let buildDir = cmakeDir & "/cmake-build-" & mode
  var libFlags =
    "-d:BrokerFfiApi --threads:on --app:lib --path:. --cc:clang --debugger:native " &
    "-d:noSignalHandler -d:useMalloc --mm:" & mm & " --outdir:" & libBuild
  if mode == "tsan":
    libFlags.add(" --tlsEmulation:off")
  libFlags.add(nimMainPrefixFlag("persistence"))
  libFlags.add(
    " --passC:" & quoteArg(sanitizerCompileFlags(mode)) & " --passL:" &
      quoteArg(sanitizerLinkFlags(mode, sharedLib = true))
  )
  libFlags.add(persistenceLibOutFlag())
  exec "nim c " & libFlags & " examples/persistence/nimlib/IPersistenceLib.nim"
  mkDir(buildDir)
  exec "cmake -S " & cmakeDir & " -B " & buildDir &
    " -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ -DCMAKE_CXX_FLAGS=" &
    quoteArg(sanitizerCompileFlags(mode)) & " -DCMAKE_EXE_LINKER_FLAGS=" &
    quoteArg(sanitizerLinkFlags(mode))
  exec "cmake --build " & buildDir & " --target persistence_cpp"
  setSanitizerEnv(mode)
  let label = "persistence cpp [" & mode & ", clang, mm:" & mm & "]"
  echo "=== RUN  " & label & " ==="
  exec quoteArg(ffiExampleExecutablePath("examples/persistence/cpp_example"))
  echo "=== PASS " & label & " ==="

task sanitizePersistenceCppAsan,
  "Build+run the persistence C++ example under ASan+UBSan (orc + refc)":
  for mm in memoryManagerMatrix():
    runSanitizedPersistenceCpp("asan", mm)

task sanitizePersistenceCppTsan,
  "Build+run the persistence C++ example under ThreadSanitizer (orc + refc)":
  for mm in memoryManagerMatrix():
    runSanitizedPersistenceCpp("tsan", mm)

# ----------------------------------------------------------------------------
# probeWinTlsUninit — minimal repro for LIMITATION.md §2.1
# ----------------------------------------------------------------------------
# Demonstrates that a Win32 RegisterWaitForSingleObject completion callback
# allocating Nim memory crashes under --mm:refc on Windows (uninitialized TLS
# on the NT thread-pool wait thread) and passes under --mm:orc. No chronos,
# no brokers — see test/probe_win_tls_uninit.nim for full discussion.
#
# Expected exit codes:
#   * Non-Windows hosts             → 77 (skip)
#   * Windows + orc                 → 0
#   * Windows + refc                → non-zero (crash); task asserts this and
#                                     exits 0 to signal "hypothesis reproduced".
proc runProbeWinTlsUninit(mm: string) =
  let outBin = "build" / ("probe_win_tls_uninit_" & mm)
  let outBinExe =
    when defined(windows):
      outBin & ".exe"
    else:
      outBin
  mkDir "build"
  # `--out:` with a path overrides `--outdir:`, so put the path directly on
  # `--out:` to land the binary under build/.
  exec "nim c --threads:on --mm:" & mm & " -d:release " & "--out:" & quoteArg(outBin) &
    " " & quoteArg("test/probe_win_tls_uninit.nim")
  # Run the probe with live stdout+stderr (exec) so a refc crash's Nim/OS
  # backtrace lands in the CI log. exec raises OSError on non-zero exit; we
  # use that to distinguish "exit 0" from "exit non-zero / crash".
  var exitedNonZero = false
  try:
    exec quoteArg(outBinExe)
  except OSError:
    exitedNonZero = true
  when defined(windows):
    if mm == "orc":
      if exitedNonZero:
        echo "::error::probeWinTlsUninit/orc: probe must succeed under ORC"
        quit(1)
      echo "probeWinTlsUninit/orc: PASS"
    else:
      # refc on Windows: we *expect* the probe to crash. If it exits 0, the
      # §2.1 hypothesis no longer reproduces and the doc needs revisiting.
      if not exitedNonZero:
        echo "::warning::probeWinTlsUninit/refc exited 0 — §2.1 hypothesis " &
          "no longer reproduces. Review doc/LIMITATION.md §2.1."
        quit(1)
      echo "probeWinTlsUninit/refc: hypothesis reproduced (probe crashed " &
        "as expected)"
  else:
    # Non-Windows hosts: probe exits 77 (skip). exec sees that as non-zero
    # → OSError → exitedNonZero=true is the success path here.
    if not exitedNonZero:
      echo "::error::probeWinTlsUninit on non-Windows: expected skip exit"
      quit(1)
    echo "probeWinTlsUninit: skipped (non-Windows host)"

task probeWinTlsUninitOrc,
  "Run the §2.1 TLS-uninit probe under --mm:orc (must pass on Windows)":
  runProbeWinTlsUninit("orc")

task probeWinTlsUninitRefc,
  "Run the §2.1 TLS-uninit probe under --mm:refc (expected to crash on Windows)":
  runProbeWinTlsUninit("refc")

task runTorpedoExampleRust, "Build the Torpedo Duel FFI library ":
  buildTorpedoExampleLibrary(generateRust = true)
  exec quoteArg(findCargoExe()) &
    " run --manifest-path examples/torpedo/rust_example/Cargo.toml"

proc writeTorpedoGoModFor(buildDir: string) =
  let modPath = "examples/torpedo/go_example/go.mod"
  var contents = "// Generated by nim-brokers test harness — do not edit.\n"
  contents.add(
    "module github.com/status-im/nim-brokers/examples/torpedo/go_example\n\n"
  )
  contents.add("go 1.21\n\n")
  contents.add("require torpedolib v0.0.0\n")
  if buildDir == "build":
    contents.add("require github.com/fxamacker/cbor/v2 v2.7.0\n")
  contents.add("\nreplace torpedolib => ../nimlib/" & buildDir & "/torpedolib_go\n")
  writeFile(modPath, contents)
  if buildDir == "build":
    withDir "examples/torpedo/go_example":
      exec quoteArg(findGoExe()) & " mod tidy"

task runTorpedoExampleGo, "Build the Torpedo Duel FFI library  + run the Go example":
  buildTorpedoExampleLibrary(generateGo = true)
  writeTorpedoGoModFor("build")
  withDir "examples/torpedo/go_example":
    exec quoteArg(findGoExe()) & " run ."

# FFI build of the torpedo example. Same torpedolib.nim source +
# same cpp_example/main.cpp, compiled against the FFI codegen output.
task buildTorpedoExample, "Build the torpedo FFI example library (into nimlib/build)":
  buildTorpedoExampleLibrary()

task buildTorpedoExampleCpp,
  "Build the Torpedo Duel C++ application against the library (via CMake)":
  buildTorpedoExampleLibrary()
  buildTorpedoCmakeTarget("torpedo_cpp")

task runTorpedoExampleCpp,
  "Build and run the Torpedo Duel C++ text UI example against the library":
  buildTorpedoExampleLibrary()
  buildTorpedoCmakeTarget("torpedo_cpp")
  exec quoteArg(torpedoExecutablePath())

task runTorpedoExamplePy,
  "Build the torpedo library + Python wrapper and run the SAME python_example/main.py against it":
  buildTorpedoExampleLibrary(true)
  putEnv("TORPEDOLIB_BUILD_DIR", "build")
  exec quoteArg(findPythonExe()) & " " &
    quoteArg("examples/torpedo/python_example/main.py")

task demoEventDrop,
  "Demo: drive the REAL threaded FFI route until the courier drops events + logs them":
  # Build benchlib (the EventBroker(API) lib) so its generated emit handler —
  # the actual production drop-warn call site — runs on a real processing
  # thread, draining to a real delivery thread.
  exec "nim c --hints:off -d:BrokerFfiApi --threads:on --app:lib --path:. " &
    "--outdir:test/ffibench/build --mm:orc " &
    "--nimMainPrefix:benchlib test/ffibench/benchlib.nim"
  mkDir("test/ffibench/cmake-build")
  exec "cmake -S test/ffibench -B test/ffibench/cmake-build"
  exec "cmake --build test/ffibench/cmake-build --target stress_event_drop_overload"
  exec "test/ffibench/build/stress_event_drop_overload"

task nph, "Install nph if needed and format modified Nim files":
  runNph(changedNimFiles(), "No modified .nim or .nimble files to format")

task nphall, "Install nph if needed and format all Nim files in the project":
  runNph(allNimFiles(), "No .nim or .nimble files found to format")

task alltests,
  "Run every test suite: test, testApi, runFfiExampleCpp, runFfiExamplePy, runTypeMapTestLibCpp, runTypeMapTestLibPy":
  exec "nimble test"
  exec "nimble runFfiExampleCpp"
  exec "nimble runFfiExamplePy"
  exec "nimble testApi"
  exec "nimble runTypeMapTestLibCpp"
  exec "nimble runTypeMapTestLibPy"

task allAsan, "Run all tests under ASan+UBSan (clang, orc/refc, debug)":
  exec "nimble testMtEventBrokerAsanOrc"
  exec "nimble testMtEventBrokerAsanRefc"
  exec "nimble testMtRequestBrokerAsanOrc"
  exec "nimble testMtRequestBrokerAsanRefc"
  exec "nimble testMtBrokerConfigsAsanOrc"
  exec "nimble testMtBrokerConfigsAsanRefc"
  exec "nimble testMtSignalBrokerAsanOrc"
  exec "nimble testMtSignalBrokerAsanRefc"
  exec "nimble testApiTeardownAsanOrc"
  exec "nimble testApiTeardownAsanRefc"
  exec "nimble testApiSignalAsanOrc"
  exec "nimble testApiSignalAsanRefc"

task allTsan,
  "Run all multi-thread + FFI-teardown tests under ThreadSanitizer (orc/refc)":
  exec "nimble testMtEventBrokerTsanOrc"
  exec "nimble testMtEventBrokerTsanRefc"
  exec "nimble testMtRequestBrokerTsanOrc"
  exec "nimble testMtRequestBrokerTsanRefc"
  exec "nimble testMtBrokerConfigsTsanOrc"
  exec "nimble testMtBrokerConfigsTsanRefc"
  exec "nimble testMtSignalBrokerTsanOrc"
  exec "nimble testMtSignalBrokerTsanRefc"
  exec "nimble testApiTeardownTsanOrc"
  exec "nimble testApiTeardownTsanRefc"
  exec "nimble testApiSignalTsanOrc"
  exec "nimble testApiSignalTsanRefc"

task allAsanLeak, "Run all tests under ASan+UBSan+LSan (Linux leak detection; orc/refc)":
  # LSan is Linux-only; on macOS/Windows these degrade to plain ASan+UBSan.
  testSan("asanleak", "orc", "test_multi_thread_event_broker")
  testSan("asanleak", "refc", "test_multi_thread_event_broker")
  testSan("asanleak", "orc", "test_multi_thread_request_broker")
  testSan("asanleak", "refc", "test_multi_thread_request_broker")
  testSan("asanleak", "orc", "test_multi_thread_broker_configs")
  testSan("asanleak", "refc", "test_multi_thread_broker_configs")
  testSan("asanleak", "orc", "test_api_event_teardown_isolation", teardownTestExtra)
  testSan("asanleak", "refc", "test_api_event_teardown_isolation", teardownTestExtra)

task allSan, "Run the full sanitizer matrix: ASan+UBSan, then ThreadSanitizer":
  exec "nimble allAsan"
  exec "nimble allTsan"
