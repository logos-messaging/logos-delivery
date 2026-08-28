#!fmt: off

import os
mode = ScriptMode.Verbose

### Package
version = "0.38.1"
author = "Status Research & Development GmbH"
description = "Logos-delivery, Private P2P Messaging for Resource-Restricted Devices"
license = "MIT or Apache License 2.0"
skipDirs = @["tests", "examples", "apps", "simulations", "metrics"]

# Nimble installs only the namesake directory; dependents need these too.
installDirs = @["library", "migrations", "tools"]

const RequiredNimVersion = "2.2.6"
  ## This is the nim compiler version that we are working on. Other versions may behave differently.
const RequiredNimbleVersion = "0.24.1"
  ## Enforced nimble version to ensure a reproducible flow
const RequiredNimbleRevision = "bc789ee6bcbfe315f81984a29318f6f8d4dcafa5"

### Dependencies
requires "nim == 2.2.6",
  "chronos >= 4.2.0 & < 4.4.0",
  "taskpools",
  # Logging & Configuration
  "chronicles",
  "confutils",
  # Serialization
  "serialization",
  "json_serialization",
  "toml_serialization",
  "faststreams",
  # Networking & P2P
  "libp2p == 2.3.1",
  # 0.9.0 is the locked version; an unversioned "eth" resolves to nim-eth HEAD,
  # which no longer ships eth/p2p/discoveryv5/enr.
  "eth == 0.9.0",
  # nat_traversal stays in the graph through libp2p, which links
  # the miniupnpc and libnatpmp static libs. Nat.mk and the iOS steps stay.
  "dnsdisc",
  "dnsclient",
  "httputils >= 0.4.1",
  "https://github.com/status-im/nim-websock#v0.4.0",
  # Cryptography
  "nimcrypto == 0.6.4", # 0.6.4 used in libp2p. Version 0.7.3 makes test to crash on Ubuntu.
  "https://github.com/status-im/nim-secp256k1#d8f1288b7c72f00be5fc2c5ea72bf5cae1eafb15",
  "bearssl",
  # RPC & APIs
  "json_rpc == 0.6.1",
  "presto",
  "https://github.com/status-im/nim-web3#cdfe5601d2812a58e54faf53ee634452d01e5918",
  # Database
  "db_connector",
  "sqlite3_abi",
  # Utilities
  "stew",
  "stint",
  "https://github.com/status-im/nim-metrics#9f2e1d4a4164deb37603b16cedd1707408ee5955",
  "regex",
  "unicodedb",
  "results",
  "minilru",
  "zlib",
  # Debug & Testing
  "testutils == 0.8.1",
  "unittest2"

# URL requirements described above.
# For commit-pinned releases, the preceding link records the associated
# upstream release tag at the time the revision was selected.

# v0.3.1-rc.0: https://github.com/logos-messaging/nim-ffi/releases/tag/v0.3.1-rc.0
requires "https://github.com/logos-messaging/nim-ffi#07ee8e1d6500762bab290465457a8d23559de546"

# No tag at pinning time; revision was 19 commits after v0.3.1-rc.0.
requires "https://github.com/logos-messaging/nim-sds.git#b12f5ee07c5b764303b51fb948b32a4ade1de3b5"

requires "https://github.com/NagyZoltanPeter/nim-brokers.git#v3.3.0"

# v0.8.1: https://github.com/vacp2p/nim-lsquic/releases/tag/v0.8.1
# libp2p requires "lsquic >= 0.5.4" by name. The exact numeric constraint
# keeps the resolution at the validated release instead of floating to
# the newest one.
requires "https://github.com/vacp2p/nim-lsquic#07783b55fb0ee7e9dc2dd9ced11548f84174306e"

requires "https://github.com/vacp2p/nim-boringssl#v0.0.11"

# No tag at pinning time; revision was one commit after v0.2.0.
requires "https://github.com/vacp2p/nim-jwt.git#057ec95eb5af0eea9c49bfe9025b3312c95dc5f2"

# Temporary pin to the mix commit that widens its libp2p requirement.
requires "https://github.com/logos-co/nim-libp2p-mix#39d2ac78da7b7f33562eb7cd95d6280ca9fa0e94"

proc getMyCPU(): string =
  ## Need to set cpu more explicit manner to avoid arch issues between dependencies
  when defined(macosx) and defined(arm64):
    return " --cpu:arm64 --passC:\"-arch arm64\" --passL:\"-arch arm64\" "
  elif defined(macosx) and defined(amd64):
    return " --cpu:amd64 --passC:\"-arch x86_64\" --passL:\"-arch x86_64\" "
  elif defined(arm64):
    return " --cpu:arm64 "
  elif defined(amd64):
    return " --cpu:amd64 "

proc getNimParams(): string =
  return " " & getEnv("NIM_PARAMS") & " "

### Helper functions
proc buildModule(filePath, params = ""): bool =
  if not dirExists "build":
    mkDir "build"

  if not fileExists(filePath):
    echo "File to build not found: " & filePath
    return false

  exec "nim c --out:build/" & filepath & ".bin --mm:refc " & getMyCPU() & getNimParams() & " " & params &
    " " & filePath

  # exec will raise exception if anything goes wrong
  return true

proc buildBinary(name: string, srcDir = "./", params = "") =
  if not dirExists "build":
    mkDir "build"
  exec "nim c --out:build/" & name & " --mm:refc " & getMyCPU() & getNimParams() & " " & params & " " &
    srcDir & name & ".nim"

## Emitted by `genBindings()` during the library build, so the header can never
## drift from the Nim signatures. Not checked in: it is a build artifact.
const cBindingsDir = "library/generated"

## `-d:ffiSrcPath` is required: without it nim-ffi derives the path with
## `relativePath`, which needs `getcwd` at compile time and fails to build.
const cBindingsFlags =
  " -d:ffiGenBindings -d:targetLang=c -d:ffiOutputDir=" & cBindingsDir &
  " -d:ffiSrcPath=../liblogosdelivery.nim "

proc buildLibrary(lib_name: string, srcDir = "./", params = "", `type` = "static", srcFile = "liblogosdelivery.nim", mainPrefix = "liblogosdelivery") =
  if not dirExists "build":
    mkDir "build"
  mkDir cBindingsDir

  if `type` == "static":
    exec "nim c" & " --out:build/" & lib_name &
      " --threads:on --app:staticlib --opt:speed --noMain --mm:refc --header -d:metrics --nimMainPrefix:" & mainPrefix & " --skipParentCfg:off -d:discv5_protocol_id=d5waku " &
      cBindingsFlags & getMyCPU() & getNimParams() & srcDir & "/" & srcFile
  else:
    exec "nim c" & " --out:build/" & lib_name &
      " --threads:on --app:lib --opt:speed --noMain --mm:refc --header -d:metrics --nimMainPrefix:" & mainPrefix & " --skipParentCfg:off -d:discv5_protocol_id=d5waku " &
      cBindingsFlags & getMyCPU() & getNimParams() & " " & srcDir & "/" & srcFile

proc buildLibDynamicWindows(libName: string, folderName: string) =
  buildLibrary libName & ".dll", folderName,
    """-d:chronicles_line_numbers --warning:Deprecated:off --warning:UnusedImport:on -d:chronicles_log_level=TRACE """,
    "dynamic", libName & ".nim", libname

proc buildLibDynamicLinux(libName: string, folderName: string) =
  buildLibrary libName & ".so", folderName,
    """-d:chronicles_line_numbers --warning:Deprecated:off --warning:UnusedImport:on -d:chronicles_log_level=TRACE """,
    "dynamic", libName & ".nim", libname

proc buildLibDynamicMac(libName: string, folderName: string) =
  let sdkPath = staticExec("xcrun --show-sdk-path").strip()
  when defined(arm64):
    let archFlags = "--cpu:arm64 --passC:\"-arch arm64\" --passL:\"-arch arm64\" --passC:\"-isysroot " & sdkPath & "\" --passL:\"-isysroot " & sdkPath & "\""
  elif defined(amd64):
    let archFlags = "--cpu:amd64 --passC:\"-arch x86_64\" --passL:\"-arch x86_64\" --passC:\"-isysroot " & sdkPath & "\" --passL:\"-isysroot " & sdkPath & "\""
  else:
    {.error: "Unsupported macOS architecture".}
  buildLibrary libName & ".dylib", folderName,
    archFlags & " -d:chronicles_line_numbers --warning:Deprecated:off --warning:UnusedImport:on -d:chronicles_log_level=TRACE",
    "dynamic", libName & ".nim", libname

proc buildLibStaticWindows(libName: string, folderName: string) =
  buildLibrary libName & ".lib", folderName,
    """-d:chronicles_line_numbers --warning:Deprecated:off --warning:UnusedImport:on -d:chronicles_log_level=TRACE """,
    "static", libName & ".nim", libname

proc buildLibStaticLinux(libName: string, folderName: string) =
  buildLibrary libName & ".a", folderName,
    """-d:chronicles_line_numbers --warning:Deprecated:off --warning:UnusedImport:on -d:chronicles_log_level=TRACE """,
    "static", libName & ".nim", libname

proc buildLibStaticMac(libName: string, folderName: string) =
  let sdkPath = staticExec("xcrun --show-sdk-path").strip()
  when defined(arm64):
    let archFlags = "--cpu:arm64 --passC:\"-arch arm64\" --passL:\"-arch arm64\" --passC:\"-isysroot " & sdkPath & "\" --passL:\"-isysroot " & sdkPath & "\""
  elif defined(amd64):
    let archFlags = "--cpu:amd64 --passC:\"-arch x86_64\" --passL:\"-arch x86_64\" --passC:\"-isysroot " & sdkPath & "\" --passL:\"-isysroot " & sdkPath & "\""
  else:
    {.error: "Unsupported macOS architecture".}
  buildLibrary libName & ".a", folderName,
    archFlags & " -d:chronicles_line_numbers --warning:Deprecated:off --warning:UnusedImport:on -d:chronicles_log_level=TRACE",
    "static", libName & ".nim", libname

### Mobile Android

proc buildMobileAndroid(srcDir = ".", params = "") =
  let cpu = getEnv("CPU")
  let abiDir = getEnv("ABIDIR")

  let outDir = "build/android/" & abiDir
  if not dirExists outDir:
    mkDir outDir

  exec "nim c" & " --out:" & outDir &
    "/liblogosdelivery.so --threads:on --app:lib --opt:speed --noMain --mm:refc -d:chronicles_sinks=textlines[dynamic] --header -d:chronosEventEngine=epoll -d:discv5_protocol_id=d5waku --passL:-L" &
    outdir & " --passL:-lrln --passL:-llog --cpu:" & cpu & " --nimMainPrefix:liblogosdelivery --os:android -d:androidNDK " & params &
    getNimParams() & " " & srcDir & "/liblogosdelivery.nim"

task libLogosDeliveryAndroid, "Build the mobile bindings for Android":
  let srcDir = "./library"
  buildMobileAndroid srcDir, "-d:chronicles_log_level=ERROR"

### Mobile iOS

import std/sequtils

proc buildMobileIOS(srcDir = ".", params = "") =
  echo "Building iOS liblogosdelivery library"

  let iosArch = getEnv("IOS_ARCH")
  let iosSdk = getEnv("IOS_SDK")
  let sdkPath = getEnv("IOS_SDK_PATH")
  let minVersion = getEnv("IOS_DEPLOYMENT_TARGET", "18.0")

  if sdkPath.len == 0:
    quit "Error: IOS_SDK_PATH not set. Set it to the path of the iOS SDK"

  # Package roots from nimble.paths — `nimble path` is unusable inside a
  # task (it mixes Info and lock-validation noise into stdout).
  proc nimblePkgPath(pkg: string): string =
    for rawLine in readFile("nimble.paths").splitLines():
      let line = rawLine.strip()
      if line.startsWith("--path:\"") and ("/pkgs2/" & pkg & "-") in line:
        return line[8 ..< line.high]
    quit "Package " & pkg & " not found in nimble.paths — run 'make build-deps' first"

  let natTraversalPath = nimblePkgPath("nat_traversal")

  # Use SDK name in path to differentiate device vs simulator
  let outDir = "build/ios/" & iosSdk & "-" & iosArch
  let nimcacheDir = outDir & "/nimcache"
  let vendorObjDir = outDir & "/vendor_obj"
  let nimLib = outDir & "/liblogosdelivery_nim.a"
  let aFile = outDir & "/liblogosdelivery.a"
  if not dirExists vendorObjDir:
    mkDir vendorObjDir

  let cpu = if iosArch == "arm64": "arm64" else: "amd64"

  # Simulator objects need the simulator flag, or Xcode refuses to link them.
  let minVersionFlag =
    if iosSdk == "iphonesimulator": "-mios-simulator-version-min=" & minVersion
    else: "-mios-version-min=" & minVersion
  let targetFlags = "-arch " & iosArch & " -isysroot " & sdkPath & " " & minVersionFlag

  # nim compiles and archives every C source it owns (generated code and the
  # {.compile.}-pragma'd dependency sources) with the iOS toolchain.
  exec "nim c" &
      " --nimcache:" & nimcacheDir &
      " --os:ios --cpu:" & cpu &
      " --app:staticlib --out:" & nimLib &
      " --noMain --mm:refc" &
      " --threads:on --opt:size --header" &
      " -d:metrics -d:discv5_protocol_id=d5waku" &
      " --nimMainPrefix:liblogosdelivery --skipParentCfg:off" &
      " --cc:clang" &
      " --passC:\"" & targetFlags & "\" --passL:\"" & targetFlags & "\"" &
      " " & params & getNimParams() &
      " " & srcDir & "/liblogosdelivery.nim"

  # nat_traversal links prebuilt archives instead of compiling its sources
  # through nim, so miniupnpc and libnatpmp are compiled here.
  let vendorClang = "clang " & targetFlags & " -fPIC -O2"

  echo "Compiling miniupnpc for iOS..."
  let miniupnpcSrcDir = natTraversalPath / "vendor/miniupnp/miniupnpc/src"
  let miniupnpcIncDir = natTraversalPath / "vendor/miniupnp/miniupnpc/include"
  let miniupnpcBuildDir = natTraversalPath / "vendor/miniupnp/miniupnpc/build"
  let miniupnpcFiles = @[
    "addr_is_reserved.c", "connecthostport.c", "igd_desc_parse.c",
    "minisoap.c", "minissdpc.c", "miniupnpc.c", "miniwget.c",
    "minixml.c", "portlistingparse.c", "receivedata.c", "upnpcommands.c",
    "upnpdev.c", "upnperrors.c", "upnpreplyparse.c"
  ]
  for fileName in miniupnpcFiles:
    let srcPath = miniupnpcSrcDir / fileName
    let oFile = vendorObjDir / ("miniupnpc_" & fileName.changeFileExt("o"))
    if fileExists(srcPath) and not fileExists(oFile):
      exec vendorClang &
          " -I" & miniupnpcIncDir &
          " -I" & miniupnpcSrcDir &
          " -I" & miniupnpcBuildDir &
          " -DMINIUPNPC_SET_SOCKET_TIMEOUT" &
          " -D_BSD_SOURCE -D_DEFAULT_SOURCE" &
          " -c " & srcPath & " -o " & oFile

  echo "Compiling libnatpmp for iOS..."
  let natpmpSrcDir = natTraversalPath / "vendor/libnatpmp-upstream"
  # Only compile natpmp.c - getgateway.c uses net/route.h which is not available on iOS
  let natpmpObj = vendorObjDir / "natpmp_natpmp.o"
  if not fileExists(natpmpObj):
    exec vendorClang &
        " -I" & natpmpSrcDir &
        " -DENABLE_STRNATPMPERR" &
        " -c " & natpmpSrcDir & "/natpmp.c -o " & natpmpObj

  # Use iOS-specific stub for getgateway
  let getgatewayStubSrc = "./library/ios_natpmp_stubs.c"
  let getgatewayStubObj = vendorObjDir / "natpmp_getgateway_stub.o"
  if fileExists(getgatewayStubSrc) and not fileExists(getgatewayStubObj):
    exec vendorClang & " -c " & getgatewayStubSrc & " -o " & getgatewayStubObj

  echo "Creating static library..."
  var inputs = @[nimLib]
  for kind, path in walkDir(vendorObjDir):
    if kind == pcFile and path.endsWith(".o"):
      inputs.add(path)
  exec "libtool -static -o " & aFile & " " & inputs.join(" ")

  let header = nimcacheDir & "/liblogosdelivery.h"
  if fileExists(header):
    cpFile(header, outDir & "/liblogosdelivery.h")

  echo "iOS library created: " & aFile

task libLogosDeliveryIOS, "Build the mobile bindings for iOS":
  let srcDir = "./library"
  let extraParams = "-d:chronicles_log_level=ERROR"
  buildMobileIOS srcDir, extraParams

proc test(name: string, params = "-d:chronicles_log_level=DEBUG") =
  # XXX: When running `> NIM_PARAMS="-d:chronicles_log_level=INFO" make test2`
  # I expect compiler flag to be overridden, however it stays with whatever is
  # specified here.
  buildBinary name, "tests/", params
  exec "build/" & name

### Waku common tasks
task testcommon, "Build & run common tests":
  test "all_tests_common", "-d:chronicles_log_level=DEBUG -d:chronosStrictException"

### Waku tasks
task wakunode2, "Build Waku v2 cli node":
  let name = "wakunode2"
  buildBinary name, "apps/wakunode2/", " -d:chronicles_log_level=TRACE "

task logosdeliverynode, "Build Logos Delivery cli node":
  let name = "logosdeliverynode"
  buildBinary name, "apps/logos_delivery_node/", " -d:chronicles_log_level=TRACE "

task benchmarks, "Some benchmarks":
  let name = "benchmarks"
  buildBinary name, "apps/benchmarks/", "-p:../.."

task wakucanary, "Build waku-canary tool":
  let name = "wakucanary"
  buildBinary name, "apps/wakucanary/"

task networkmonitor, "Build network monitor tool":
  let name = "networkmonitor"
  buildBinary name, "apps/networkmonitor/"

task rln_db_inspector, "Build the rln db inspector":
  let name = "rln_db_inspector"
  buildBinary name, "tools/rln_db_inspector/"

task test, "Build & run Waku tests":
  test "all_tests_waku"

task testwakunode2, "Build & run wakunode2 app tests":
  test "all_tests_wakunode2"

task example2, "Build Waku examples":
  buildBinary "api_example", "examples/api_example/"
  buildBinary "publisher", "examples/"
  buildBinary "subscriber", "examples/"
  buildBinary "filter_subscriber", "examples/"
  buildBinary "lightpush_publisher", "examples/"

task chat2, "Build example Waku chat usage":
  # NOTE For debugging, set debug level. For chat usage we want minimal log
  # output to STDOUT. Can be fixed by redirecting logs to file (e.g.)
  #buildBinary name, "examples/", "-d:chronicles_log_level=WARN"

  let name = "chat2"
  buildBinary name,
    "apps/chat2/",
    "-d:chronicles_sinks=textlines[file] -d:chronicles_log_level=TRACE "
  #  -d:ssl - cause unlisted exception error in libp2p/utility...

task chat2mix, "Build example Waku chat mix usage":
  # NOTE For debugging, set debug level. For chat usage we want minimal log
  # output to STDOUT. Can be fixed by redirecting logs to file (e.g.)
  #buildBinary name, "examples/", "-d:chronicles_log_level=WARN"

  let name = "chat2mix"
  buildBinary name,
    "apps/chat2mix/",
    "-d:chronicles_sinks=textlines[file] -d:chronicles_log_level=TRACE "
  #  -d:ssl - cause unlisted exception error in libp2p/utility...

task chat2bridge, "Build chat2bridge":
  let name = "chat2bridge"
  buildBinary name, "apps/chat2bridge/"

task liteprotocoltester, "Build liteprotocoltester":
  let name = "liteprotocoltester"
  buildBinary name, "apps/liteprotocoltester/", "-d:chronicles_log_level=TRACE"

task lightpushwithmix, "Build lightpushwithmix":
  let name = "lightpush_publisher_mix"
  buildBinary name, "examples/lightpush_mix/"

task buildTest, "Test custom target":
  let args = commandLineParams()
  if args.len == 0:
    quit "Missing test file"

  let filepath = args[^1]
  discard buildModule(filepath)

import std/strutils

task execTest, "Run test":
  let args = commandLineParams()
  if args.len == 0:
    quit "Missing arguments"
  # expects: <file> "<test name>"
  let filepath =
    if args.len >= 2: args[^2]
    else: args[^1]
  var testSuite =
    if args.len >= 1: args[^1].strip(chars = {'\"'})
    else: ""
  if testSuite != "":
    testSuite = " \"" & testSuite & "\""
  exec "build/" & filepath & ".bin " & testSuite

### C Bindings
let chroniclesParams =
  "-d:chronicles_line_numbers " & "-d:chronicles_runtime_filtering=on " &
  """-d:chronicles_sinks="textlines,json" """ &
  "-d:chronicles_default_output_device=Dynamic " &
  """-d:chronicles_disabled_topics="eth,dnsdisc.client" """ & "--warning:Deprecated:off " &
  "--warning:UnusedImport:on " & "-d:chronicles_log_level=TRACE"

## Liblogosdelivery build tasks

task liblogosdelivery, "Build liblogosdelivery for the host platform":
  when defined(windows):
    buildLibDynamicWindows("liblogosdelivery", "library")
  elif defined(macosx):
    buildLibDynamicMac("liblogosdelivery", "library")
  else:
    buildLibDynamicLinux("liblogosdelivery", "library")

task liblogosdeliveryDynamicWindows, "Generate bindings":
  buildLibDynamicWindows("liblogosdelivery", "library")

task liblogosdeliveryDynamicLinux, "Generate bindings":
  buildLibDynamicLinux("liblogosdelivery", "library")

task liblogosdeliveryDynamicMac, "Generate bindings":
  buildLibDynamicMac("liblogosdelivery", "library")

task liblogosdeliveryStaticWindows, "Generate bindings":
  buildLibStaticWindows("liblogosdelivery", "library")

task liblogosdeliveryStaticLinux, "Generate bindings":
  buildLibStaticLinux("liblogosdelivery", "library")

task liblogosdeliveryStaticMac, "Generate bindings":
  buildLibStaticMac("liblogosdelivery", "library")

### Formatting tasks

task nphchanges, "Run nph on .nim/.nims/.nimble files changed on this branch/PR":
  ## Formats every Nim source file that differs from the base branch.
  ## The set covers committed changes on the branch, working-tree edits
  ## (staged or not) and untracked files. The base branch is auto-detected
  ## (origin's default branch, else local main/master); override it with
  ## the NPH_BASE_BRANCH env var.
  let nph =
    if findExe("nph").len > 0: findExe("nph")
    else: getHomeDir() / ".nimble" / "bin" / "nph"
  if not fileExists(nph):
    quit "nph not found. Run `make build-nph` first.", 1

  proc detectBaseBranch(): string =
    # Explicit override wins.
    if existsEnv("NPH_BASE_BRANCH"):
      return getEnv("NPH_BASE_BRANCH")
    # origin's default branch, e.g. "origin/main" -> "main".
    let (head, hCode) =
      gorgeEx("git symbolic-ref --short refs/remotes/origin/HEAD")
    if hCode == 0 and head.strip().len > 0:
      let parts = head.strip().split('/')
      return parts[^1]
    # Fall back to whichever local branch exists.
    for candidate in ["main", "master"]:
      let (_, vCode) =
        gorgeEx("git rev-parse --verify --quiet " & candidate)
      if vCode == 0:
        return candidate
    return "master"

  let baseBranch = detectBaseBranch()

  # Diff against the merge-base so we only touch what this branch introduced.
  var diffRef = baseBranch
  let (mergeBase, mbCode) = gorgeEx("git merge-base HEAD " & baseBranch)
  if mbCode == 0 and mergeBase.strip().len > 0:
    diffRef = mergeBase.strip()

  let (changed, dCode) = gorgeEx("git diff --name-only --diff-filter=ACMR " & diffRef)
  if dCode != 0:
    quit "git diff failed: " & changed, 1
  let (untracked, _) = gorgeEx("git ls-files --others --exclude-standard")

  var files: seq[string]
  for line in (changed & "\n" & untracked).splitLines():
    let f = line.strip()
    if f.len == 0:
      continue
    if not (f.endsWith(".nim") or f.endsWith(".nims") or f.endsWith(".nimble")):
      continue
    if fileExists(f) and f notin files:
      files.add(f)

  if files.len == 0:
    echo "nphchanges: no changed .nim/.nims/.nimble files to format"
    return

  echo "nphchanges: formatting " & $files.len & " file(s) (base: " & baseBranch & ")"
  for f in files:
    echo "Formatting " & f
    exec nph & " \"" & f & "\""
