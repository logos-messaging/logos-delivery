# ffi.nimble

version = "0.3.0"
author = "Institute of Free Technology"
description = "FFI framework with custom header generation"
license = "MIT or Apache License 2.0"

packageName = "ffi"

requires "nim >= 2.2.6"
requires "chronos"
requires "chronicles"
requires "taskpools"
requires "cbor_serialization == 0.3.0"

const nimFlagsOrc = "--mm:orc -d:chronicles_log_level=WARN"
const nimFlagsRefc = "--mm:refc -d:chronicles_log_level=WARN"

const timerSrc = "examples/timer/timer.nim"
const echoSrc = "examples/echo/echo.nim"

import std/[algorithm, os, strutils]

proc discoverUnitTests(): seq[string] =
  # `listFiles` returns both .nim sources and any compiled binaries left in
  # the dir from prior local runs — filter to .nim so we don't run a test
  # twice (and don't try to `nim c -r` a stale binary).
  var names: seq[string] = @[]
  for path in listFiles(thisDir() / "tests/unit"):
    if path.endsWith(".nim"):
      let name = path.extractFilename.changeFileExt("")
      if name.startsWith("test_"):
        names.add(name)
  names.sort()
  return names

let unitTests = discoverUnitTests()

proc runOrQuit(cmd: string) =
  # Workaround for newer nimble (shipping with Nim 2.2.10+) printing the
  # OSError from a failed `exec` but exiting 0, which causes CI to report
  # green on actual build/test failures. Echo the command first so the log
  # makes clear which step failed.
  try:
    exec cmd
  except OSError as e:
    echo "command failed: ", cmd
    echo "error: ", e.msg
    quit(QuitFailure)

proc checkBindingsDiff(regenCmd: string, paths: openArray[string]) =
  # On a diff, print a remediation hint instead of a bare diff wall. Re-quitting
  # non-zero also dodges the nimble ≥2.2.10 exit-0-on-failure footgun (runOrQuit).
  try:
    exec "git diff --exit-code -- " & paths.join(" ")
  except OSError:
    echo "Checked-in bindings are stale. Run `" & regenCmd & "` and commit the result."
    quit(QuitFailure)

proc sanFlags(san: string): string =
  # Each --passC / --passL adds one literal flag to the C compiler / linker
  # invocation — avoids any quoting ambiguity that arises from putting
  # space-separated flags inside a single --passC argument.
  #
  # `asan-ubsan` enables LeakSanitizer too: ASan includes LSan, so leaks are
  # reported when ASAN_OPTIONS=detect_leaks=1 (set by the sanitizer CI job).
  case san
  of "none", "":
    ""
  of "asan-ubsan":
    " --passC:-fsanitize=address,undefined" & " --passC:-fno-sanitize-recover=all" &
      " --passC:-fno-omit-frame-pointer" & " --passC:-g" &
      " --passL:-fsanitize=address,undefined"
  of "tsan":
    " --passC:-fsanitize=thread" & " --passC:-fno-omit-frame-pointer" & " --passC:-g" &
      " --passC:-O1" & " --passL:-fsanitize=thread"
  else:
    raise newException(ValueError, "unknown NIM_FFI_SAN: " & san)

proc mmModes(): seq[string] =
  ## Memory-management modes to build under, selected by NIM_FFI_MM (empty = both).
  case getEnv("NIM_FFI_MM", "")
  of "orc":
    @[nimFlagsOrc]
  of "refc":
    @[nimFlagsRefc]
  else:
    @[nimFlagsOrc, nimFlagsRefc]

proc applyTsanSuppressions() =
  ## Adds tsan.supp to TSAN_OPTIONS without clobbering options the CI job set.
  let suppPath = thisDir() & "/tsan.supp"
  let existing = getEnv("TSAN_OPTIONS")
  if existing == "":
    putEnv("TSAN_OPTIONS", "suppressions=" & suppPath)
  elif "suppressions=" notin existing:
    putEnv("TSAN_OPTIONS", existing & ":suppressions=" & suppPath)

proc genBindingsCmd(flags, src: string, langs = "rust", outDir = ""): string =
  ## One `nim c` that emits `langs` (comma-separated) from `src`. Output dir and
  ## embedded source path default to `<lang>_bindings/` next to `src`; `outDir`
  ## overrides every language. `--compileOnly` is enough because the binding
  ## files are written during macro expansion — nothing is linked.
  var cmd =
    "nim c " & flags & " -d:ffiGenBindings -d:targetLang=" & langs & " --compileOnly"
  if outDir.len > 0:
    cmd.add " -d:ffiOutputDir=" & outDir
  cmd.add " " & src
  cmd

proc removeStaleEchoLib() =
  ## CMake keys the shared `libecho.so` rebuild on echo.nim's mtime, not on
  ## `-d:ffiEchoAbiC`, so a stale lib from the other ABI is reused and segfaults.
  ## Every echo e2e task deletes it first to force a fresh rebuild.
  for name in ["libecho.so", "libecho.dylib", "echo.dll"]:
    let path = thisDir() / name
    if fileExists(path):
      rmFile(path)

task buildffi, "Compile the library":
  exec "nim c " & nimFlagsOrc & " --app:lib --noMain ffi.nim"

task test, "Run all tests under --mm:orc and --mm:refc":
  for flags in [nimFlagsOrc, nimFlagsRefc]:
    for t in unitTests:
      exec "nim c -r " & flags & " tests/unit/" & t & ".nim"

task test_alloc, "Run alloc unit tests under --mm:orc and --mm:refc":
  exec "nim c -r " & nimFlagsOrc & " tests/unit/test_alloc.nim"
  exec "nim c -r " & nimFlagsRefc & " tests/unit/test_alloc.nim"

task test_ffi, "Run FFI context integration tests under --mm:orc and --mm:refc":
  exec "nim c -r " & nimFlagsOrc & " tests/unit/test_ffi_context.nim"
  exec "nim c -r " & nimFlagsRefc & " tests/unit/test_ffi_context.nim"

task test_serial, "Run CBOR codec unit tests":
  exec "nim c -r " & nimFlagsOrc & " tests/unit/test_serial.nim"
  exec "nim c -r " & nimFlagsRefc & " tests/unit/test_serial.nim"

task bench_codec, "Microbenchmark: cbor vs c (cwire) wire-format codecs":
  # Built with -d:danger so the numbers reflect optimized codegen, not the
  # debug build. Not part of `test` — timing is a measurement, not a gate.
  exec "nim c -r " & nimFlagsOrc & " -d:danger tests/bench/bench_codec.nim"

task bench_ffi_submit,
  "Concurrent-submit stress + scaling gate for sendRequestToFFIThread":
  # Honors NIM_FFI_SAN / NIM_FFI_MM like test_sanitized so CI drives it under
  # asan-ubsan and tsan; FFI_SUBMIT_PER_THREAD sets per-thread volume.
  let san = getEnv("NIM_FFI_SAN", "none")
  let extra = sanFlags(san)
  if san == "tsan":
    applyTsanSuppressions()
  for flags in mmModes():
    exec "nim c -r " & flags & " -d:danger" & extra & " tests/bench/bench_ffi_submit.nim"

task test_cpp_e2e, "Build and run the C++ end-to-end tests for the timer example":
  # Regenerate the C++ bindings so the suite always runs against fresh codegen.
  runOrQuit "nimble genbindings_cpp"
  runOrQuit "nimble genbindings_cpp_echo"
  # Force a fresh CBOR libecho: a prior abi=c run leaves a same-named dylib that
  # cmake would otherwise reuse, mismatching the CBOR bindings (segfault).
  removeStaleEchoLib()
  runOrQuit "cmake -S tests/e2e/cpp -B tests/e2e/cpp/build"
  runOrQuit "cmake --build tests/e2e/cpp/build --config Debug"
  # `-C Debug` is required on Windows multi-config generators because
  # gtest_discover_tests(PRE_TEST) loads per-config include files; harmless on
  # single-config generators (Make/Ninja) on Linux/macOS.
  runOrQuit "ctest --test-dir tests/e2e/cpp/build --output-on-failure -C Debug"

task test_c_e2e, "Build and run the C end-to-end tests for the timer example":
  # Regenerate the C bindings so the suite always runs against fresh codegen.
  runOrQuit "nimble genbindings_c"
  runOrQuit "cmake -S tests/e2e/c -B tests/e2e/c/build"
  runOrQuit "cmake --build tests/e2e/c/build --config Debug"
  runOrQuit "ctest --test-dir tests/e2e/c/build --output-on-failure -C Debug"

task test_c_abi_e2e, "Build and run the CBOR-free abi=c C end-to-end test (echo)":
  runOrQuit "nimble genbindings_c_abi_echo"
  removeStaleEchoLib()
  runOrQuit "cmake -S tests/e2e/c_abi -B tests/e2e/c_abi/build"
  runOrQuit "cmake --build tests/e2e/c_abi/build --config Debug"
  runOrQuit "ctest --test-dir tests/e2e/c_abi/build --output-on-failure -C Debug"

task test_sanitized,
  "Run all unit tests under a sanitizer (NIM_FFI_SAN) and mm (NIM_FFI_MM)":
  let san = getEnv("NIM_FFI_SAN", "none")
  let extra = sanFlags(san)
  if san == "tsan":
    applyTsanSuppressions()
  for flags in mmModes():
    for t in unitTests:
      exec "nim c -r " & flags & extra & " tests/unit/" & t & ".nim"

task test_cpp_e2e_sanitized,
  "Build and run the C++ e2e tests with a sanitizer (NIM_FFI_SAN) and mm (NIM_FFI_MM)":
  let mm = getEnv("NIM_FFI_MM", "orc")
  let san = getEnv("NIM_FFI_SAN", "none")
  runOrQuit "nimble genbindings_cpp"
  runOrQuit "nimble genbindings_cpp_echo"
  # See test_cpp_e2e: force a fresh CBOR libecho so a prior abi=c dylib can't be
  # reused against the CBOR bindings.
  removeStaleEchoLib()
  runOrQuit "cmake -S tests/e2e/cpp -B tests/e2e/cpp/build" & " -DNIM_FFI_MM=" & mm &
    " -DNIM_FFI_SANITIZER=" & san
  runOrQuit "cmake --build tests/e2e/cpp/build --config Debug -j"
  runOrQuit "ctest --test-dir tests/e2e/cpp/build --output-on-failure -C Debug"

task test_c_e2e_sanitized,
  "Build and run the C e2e tests with a sanitizer (NIM_FFI_SAN) and mm (NIM_FFI_MM)":
  let mm = getEnv("NIM_FFI_MM", "orc")
  let san = getEnv("NIM_FFI_SAN", "none")
  runOrQuit "nimble genbindings_c"
  runOrQuit "cmake -S tests/e2e/c -B tests/e2e/c/build" & " -DNIM_FFI_MM=" & mm &
    " -DNIM_FFI_SANITIZER=" & san
  runOrQuit "cmake --build tests/e2e/c/build --config Debug -j"
  runOrQuit "ctest --test-dir tests/e2e/c/build --output-on-failure -C Debug"

task test_c_abi_e2e_sanitized,
  "Build and run the abi=c C e2e test with a sanitizer (NIM_FFI_SAN)":
  let san = getEnv("NIM_FFI_SAN", "none")
  runOrQuit "nimble genbindings_c_abi_echo"
  removeStaleEchoLib()
  runOrQuit "cmake -S tests/e2e/c_abi -B tests/e2e/c_abi/build" & " -DNIM_FFI_SANITIZER=" &
    san
  runOrQuit "cmake --build tests/e2e/c_abi/build --config Debug -j"
  runOrQuit "ctest --test-dir tests/e2e/c_abi/build --output-on-failure -C Debug"

task genbindings_example, "Generate Rust bindings for the timer example":
  exec genBindingsCmd(nimFlagsOrc, timerSrc)
  exec genBindingsCmd(nimFlagsRefc, timerSrc)

task genbindings_rust, "Generate Rust bindings for the timer example":
  exec genBindingsCmd(nimFlagsOrc, timerSrc, "rust")
  exec genBindingsCmd(nimFlagsRefc, timerSrc, "rust")

task genbindings_cddl, "Generate CDDL schema for the timer example":
  exec genBindingsCmd(nimFlagsOrc, timerSrc, "cddl")

task genbindings_cpp, "Generate C++ bindings for the timer example":
  exec genBindingsCmd(nimFlagsOrc, timerSrc, "cpp")
  exec genBindingsCmd(nimFlagsRefc, timerSrc, "cpp")

task genbindings_cpp_echo, "Generate C++ bindings for the echo example":
  exec genBindingsCmd(nimFlagsOrc, echoSrc, "cpp")
  exec genBindingsCmd(nimFlagsRefc, echoSrc, "cpp")

task genbindings_c, "Generate C bindings for the timer example":
  exec genBindingsCmd(nimFlagsOrc, timerSrc, "c")
  exec genBindingsCmd(nimFlagsRefc, timerSrc, "c")

task genbindings_c_echo, "Generate C bindings for the echo example":
  exec genBindingsCmd(nimFlagsOrc, echoSrc, "c")
  exec genBindingsCmd(nimFlagsRefc, echoSrc, "c")

task genbindings_c_abi_echo, "Generate CBOR-free abi=c C bindings for the echo example":
  # abiOut forces output beside the CBOR `c_bindings/` instead of overwriting it.
  const abiOut = "examples/echo/c_abi_bindings"
  const abiFlags = " -d:ffiEchoAbiC -d:ffiSrcPath=../echo.nim"
  exec genBindingsCmd(nimFlagsOrc & abiFlags, echoSrc, "c", abiOut)
  exec genBindingsCmd(nimFlagsRefc & abiFlags, echoSrc, "c", abiOut)

task check_bindings_rust, "Verify checked-in Rust bindings match Nim source":
  runOrQuit "nimble genbindings_rust"
  checkBindingsDiff(
    "nimble genbindings_rust",
    [
      "examples/timer/rust_bindings/Cargo.toml",
      "examples/timer/rust_bindings/build.rs", "examples/timer/rust_bindings/src",
    ],
  )

task check_bindings_cpp, "Verify checked-in C++ bindings match Nim source":
  runOrQuit "nimble genbindings_cpp"
  runOrQuit "nimble genbindings_cpp_echo"
  checkBindingsDiff(
    "nimble genbindings_cpp && nimble genbindings_cpp_echo",
    [
      "examples/timer/cpp_bindings/my_timer.hpp",
      "examples/timer/cpp_bindings/CMakeLists.txt",
      "examples/echo/cpp_bindings/echo.hpp", "examples/echo/cpp_bindings/CMakeLists.txt",
    ],
  )

task check_bindings_c, "Verify checked-in C bindings match Nim source":
  runOrQuit "nimble genbindings_c"
  runOrQuit "nimble genbindings_c_echo"
  checkBindingsDiff(
    "nimble genbindings_c && nimble genbindings_c_echo",
    [
      "examples/timer/c_bindings/my_timer.h",
      "examples/timer/c_bindings/nim_ffi_prelude.h",
      "examples/timer/c_bindings/nim_ffi_cbor.h",
      "examples/timer/c_bindings/CMakeLists.txt", "examples/echo/c_bindings/echo.h",
      "examples/echo/c_bindings/nim_ffi_prelude.h",
      "examples/echo/c_bindings/nim_ffi_cbor.h",
      "examples/echo/c_bindings/CMakeLists.txt",
    ],
  )

task check_bindings_c_abi, "Verify checked-in abi=c C bindings match Nim source":
  runOrQuit "nimble genbindings_c_abi_echo"
  checkBindingsDiff(
    "nimble genbindings_c_abi_echo",
    [
      "examples/echo/c_abi_bindings/echo.h",
      "examples/echo/c_abi_bindings/CMakeLists.txt",
    ],
  )

task check_bindings, "Verify all checked-in example bindings match Nim source":
  exec "nimble check_bindings_rust"
  exec "nimble check_bindings_cpp"
  exec "nimble check_bindings_c"
  exec "nimble check_bindings_c_abi"
