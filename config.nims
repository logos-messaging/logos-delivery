import os, strutils

# The all_tests_* binaries compile the same dependency tree with the same flags,
# so one cache between them lets every build after the first reuse the objects
# instead of generating and compiling the tree again. Single-file test builds
# keep a cache of their own: buildModule passes no chronicles level, so their
# objects differ.
let nimcacheName =
  if projectName().startsWith("all_tests_"):
    "all_tests"
  else:
    projectName()

if defined(release):
  switch("nimcache", "nimcache/release/" & nimcacheName)
else:
  switch("nimcache", "nimcache/debug/" & nimcacheName)

if defined(windows):
  if not defined(disable_rln):
    switch("passL", "rln.lib")
  switch("define", "postgres=false")

  # disable timestamps in Windows PE headers - https://wiki.debian.org/ReproducibleBuilds/TimestampsInPEBinaries
  switch("passL", "-Wl,--no-insert-timestamp")
  # increase stack size
  switch("passL", "-Wl,--stack,8388608")
  # https://github.com/nim-lang/Nim/issues/4057
  --tlsEmulation:
    off
  if defined(i386):
    # set the IMAGE_FILE_LARGE_ADDRESS_AWARE flag so we can use PAE, if enabled, and access more than 2 GiB of RAM
    switch("passL", "-Wl,--large-address-aware")

# CPU baseline. The default build is portable. -d:marchNative selects the native flags.
# -d:disableMarchNative, the former name of the portable build, still works and wins.
const portableBuild = not defined(marchNative) or defined(disableMarchNative)

# Leopard-RS is built by nim-leopard, which shells out to cmake from a `static:`
# block outside Nim's flag plumbing: nothing passed with --passC/--cpu/--os
# reaches Leopard-RS' compiler, so every knob it has -- all strdefines -- has to
# be assembled here.
#
# nim-leopard also skips cmake entirely when its archive is already in nimcache,
# and nimcache is not keyed by defines: a tree first built with other flags keeps
# the old archive. Use -d:LeopardRebuild or wipe nimcache when switching.
if defined(android):
  # cmake runs on the build host, so left alone it hands Leopard-RS the host's
  # x86-64 compiler and produces an archive that cannot link into the target
  # .so. Point it at the same NDK clang this file gives Nim, and define ANDROID
  # so Leopard-RS takes its LEO_TARGET_MOBILE path instead of including
  # <tmmintrin.h>. -march=native must stay off even here: the x86_64 ABI's NDK
  # clang accepts it, and would then tune for the build machine.
  let ndkClang = getEnv("ANDROID_TOOLCHAIN_DIR") & "/bin/" & getEnv("ANDROID_COMPILER")
  switch(
    "define",
    "LeopardCmakeFlags=-DCMAKE_BUILD_TYPE=Release -DENABLE_OPENMP=off" &
      " -DCMAKE_POSITION_INDEPENDENT_CODE=ON" &
      " -DCOMPILER_SUPPORTS_MARCH_NATIVE=FALSE -DCMAKE_SYSTEM_NAME=Linux" &
      " -DCMAKE_C_COMPILER=" & ndkClang & " -DCMAKE_CXX_COMPILER=" & ndkClang &
      "++ -DCMAKE_CXX_FLAGS=-DANDROID",
  )
  # nim-leopard's non-macOS defaults add -fopenmp, and the NDK resolves its
  # -lomp to a shared libomp.so that every consumer of our .so would then have
  # to ship. Leopard is built without OpenMP above, so drop it on this side too.
  switch("define", "LeopardExtraCompilerFlags=-fno-openmp")
  switch("define", "LeopardExtraLinkerFlags=-fno-openmp")
  # Leopard-RS is C++ and allocates its tables with `new[]`. Everywhere else Nim
  # notices the mixed-mode build and links through the C++ driver, which brings
  # the runtime in by itself; here the android section below pins
  # clang.linkerexe to the NDK's C driver, which does not. Name libc++
  # explicitly, and take the static one so the .so stays self-contained -- a
  # -shared link does not fail on the missing symbols, it just defers them to
  # dlopen on the device.
  switch("passL", "-lc++_static")
  switch("passL", "-lc++abi")
elif portableBuild:
  # Leopard-RS' CMakeLists adds -march=native whenever the compiler accepts it.
  # Seed the cache variable guarding that probe so a portable build stays
  # portable -- and hand leopard the same x86 baseline this file gives the C
  # compiler below, because Leopard-RS includes <tmmintrin.h> unconditionally and
  # its SSSE3 intrinsics (_mm_shuffle_epi8) do not compile without an enabling
  # flag. Its AVX2 paths are gated on __AVX2__, so they drop out on their own.
  var leopardCxxFlags = ""
  if defined(i386) or defined(amd64):
    if defined(macosx):
      leopardCxxFlags = " -DCMAKE_CXX_FLAGS=-march=haswell"
    elif defined(marchOptimized):
      leopardCxxFlags = " -DCMAKE_CXX_FLAGS=-march=x86-64-v2"
    else:
      leopardCxxFlags = " -DCMAKE_CXX_FLAGS=-mssse3"

  # Mirrors nim-leopard's own per-platform default, less -march=native.
  let leopardCmakeBase =
    if defined(macosx):
      "-DCMAKE_BUILD_TYPE=Release -DENABLE_OPENMP=off"
    elif defined(windows):
      "-G\"MSYS Makefiles\" -DCMAKE_BUILD_TYPE=Release"
    else:
      "-DCMAKE_BUILD_TYPE=Release"

  # -fPIC: Leopard-RS builds a static archive, and on ELF that archive also has
  # to go into liblogosdelivery.so. Only the shared-library target needs it, and
  # config.nims cannot tell which target is being built, so ask for it always --
  # elsewhere it is already the default (Mach-O, the NDK, nixpkgs' hardening),
  # which is why a non-PIC archive got this far unnoticed.
  switch(
    "define",
    "LeopardCmakeFlags=" & leopardCmakeBase &
      " -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCOMPILER_SUPPORTS_MARCH_NATIVE=FALSE" &
      leopardCxxFlags,
  )
if portableBuild:
  switch("define", "disableMarchNative")
  # https://github.com/status-im/nimbus-eth2/blob/stable/docs/cpu_features.md#ssse3-supplemental-sse3
  # suggests that SHA256 hashing with SSSE3 is 20% faster than without SSSE3, so
  # given its near-ubiquity in the x86 installed base, it renders a distribution
  # build more viable on an overall broader range of hardware.
  if defined(i386) or defined(amd64):
    if defined(macosx):
      # macOS Catalina is EOL as of 2022-09
      # https://support.apple.com/kb/sp833
      # "macOS Big Sur - Technical Specifications" lists current oldest
      # supported models: MacBook (2015 or later), MacBook Air (2013 or later),
      # MacBook Pro (Late 2013 or later), Mac mini (2014 or later), iMac (2014
      # or later), iMac Pro (2017 or later), Mac Pro (2013 or later).
      #
      # These all have Haswell or newer CPUs.
      #
      # This ensures AVX2, AES-NI, PCLMUL, BMI1, and BMI2 instruction set support.
      switch("passC", "-march=haswell -mtune=generic")
      switch("passL", "-march=haswell -mtune=generic")
    else:
      if defined(marchOptimized):
        # -march=broadwell: https://github.com/status-im/nimbus-eth2/blob/stable/docs/cpu_features.md#bmi2--adx
        # Changed to x86-64-v2 for broader support
        switch("passC", "-march=x86-64-v2 -mtune=generic")
        switch("passL", "-march=x86-64-v2 -mtune=generic")
      else:
        switch("passC", "-mssse3")
        switch("passL", "-mssse3")
elif defined(ios):
  # Cross build: the target flags come from the build task.
  discard
elif defined(macosx) and defined(arm64):
  # Apple's Clang can't handle "-march=native" on M1: https://github.com/status-im/nimbus-eth2/issues/2758
  switch("passC", "-mcpu=apple-m1")
  switch("passL", "-mcpu=apple-m1")
else:
  if not defined(android):
    switch("passC", "-march=native")
    switch("passL", "-march=native")
  if defined(windows):
    # https://gcc.gnu.org/bugzilla/show_bug.cgi?id=65782
    # ("-fno-asynchronous-unwind-tables" breaks Nim's exception raising, sometimes)
    switch("passC", "-mno-avx512f")
    switch("passL", "-mno-avx512f")

when defined(macosx):
  # TEMPORARY (added 2026-06-19) — remove once nim-chronos is fixed/bumped upstream.
  #
  # macOS / Apple Clang 16+ promotes -Wincompatible-function-pointer-types to a
  # DEFAULT error (not gated behind -Werror). It fires on a dependency↔dependency
  # call in nim-chronos — none of our code is involved:
  #   chronos/streams/tlsstream.nim:718  ctx.setdest(itemAppend, ...)
  # chronos declares the PEM callback `itemAppend(ctx, pbytes: pointer, nbytes)`
  # while bearssl's `br_pem_decoder_setdest` expects `pbytes: const void*`. The
  # callback only READS the buffer (copyMem from pbytes), so the missing `const`
  # is benign — we demote the diagnostic back to a warning instead of failing.
  #
  # Proper fix: chronos should declare `itemAppend`'s `pbytes` as `const pointer`.
  switch("passC", "-Wno-error=incompatible-function-pointer-types")

--threads:
  on
--opt:
  speed

# All feature defines go here
--define:
  libp2p_mix_experimental_exit_is_dest

--excessiveStackTrace:
  on
# enable metric collection
--define:
  metrics
# for heap-usage-by-instance-type metrics and object base-type strings
--define:
  nimTypeNames

# the default open files limit is too low on macOS (512), breaking the
# "--debugger:native" build. It can be increased with `ulimit -n 1024`.
if not defined(macosx) and not defined(android):
  # add debugging symbols and original files and line numbers
  --debugger:
    native
  when defined(enable_libbacktrace):
    # light-weight stack traces using libbacktrace and libunwind
    # opt-in: pass -d:enable_libbacktrace (requires libbacktrace in project deps)
    --define:
      nimStackTraceOverride
    switch("import", "libbacktrace")

--define:
  nimOldCaseObjects
  # https://github.com/status-im/nim-confutils/issues/9

# `switch("warning[CaseTransition]", "off")` fails with "Error: invalid command line option: '--warning[CaseTransition]'"
switch("warning", "CaseTransition:off")

# The compiler doth protest too much, methinks, about all these cases where it can't
# do its (N)RVO pass: https://github.com/nim-lang/RFCs/issues/230
switch("warning", "ObservableStores:off")

# Too many false positives for "Warning: method has lock level <unknown>, but another method has 0 [LockLevel]"
switch("warning", "LockLevel:off")

if defined(android):
  var clang = getEnv("ANDROID_COMPILER")
  var ndk_home = getEnv("ANDROID_TOOLCHAIN_DIR")
  var sysroot = ndk_home & "/sysroot"
  var cincludes = sysroot & "/usr/include/" & getEnv("ANDROID_ARCH")

  switch("clang.path", ndk_home & "/bin")
  switch("clang.exe", clang)
  switch("clang.linkerexe", clang)
  switch("passC", "--sysroot=" & sysRoot)
  switch("passL", "--sysroot=" & sysRoot)
  switch("cincludes", sysRoot & "/usr/include/")

# begin Nimble config (version 2)
--noNimblePath
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config
