#!fmt: off

import os
mode = ScriptMode.Verbose

### Package
version = "0.36.0"
author = "Status Research & Development GmbH"
description = "Waku, Private P2P Messaging for Resource-Restricted Devices"
license = "MIT or Apache License 2.0"

### Dependencies
requires "nim >= 2.2.4",
  # Async & Concurrency
  "chronos >= 4.2.0",
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
  "libp2p >= 1.15.1",
  "eth",
  "nat_traversal",
  "dnsdisc",
  "dnsclient",
  "httputils",
  # Cryptography
  "nimcrypto",
  "secp256k1",
  "bearssl",
  # RPC & APIs
  "json_rpc",
  "presto",
  "web3",
  "jwt",
  # Database
  "db_connector",
  "sqlite3_abi",
  # Utilities
  "stew",
  "stint",
  "metrics",
  "regex",
  "unicodedb",
  "results",
  "minilru",
  "zlib",
  # Debug & Testing
  "testutils",
  "unittest2"

# We use a custom branch to allow higher chronos versions, like nim-chronos 4.2.0
requires "https://github.com/status-im/nim-websock.git#allow-high-chronos-versions"

# Packages not on nimble (use git URLs)
requires "https://github.com/vacp2p/nim-lsquic"
requires "https://github.com/logos-messaging/nim-ffi"

### Helper functions
proc buildModule(filePath, params = "", lang = "c"): bool =
  if not dirExists "build":
    mkDir "build"
  # allow something like "nim nimbus --verbosity:0 --hints:off nimbus.nims"
  var extra_params = params
  for i in 2 ..< paramCount() - 1:
    extra_params &= " " & paramStr(i)

  if not fileExists(filePath):
    echo "File to build not found: " & filePath
    return false

  exec "nim " & lang & " --out:build/" & filepath & ".bin --mm:refc " & extra_params &
    " " & filePath

  # exec will raise exception if anything goes wrong
  return true

proc buildBinary(name: string, srcDir = "./", params = "", lang = "c") =
  if not dirExists "build":
    mkDir "build"
  # Get extra params from NIM_PARAMS environment variable
  var extra_params = params
  let nimParams = getEnv("NIM_PARAMS")
  if nimParams.len > 0:
    extra_params &= " " & nimParams
  exec "nim " & lang & " --out:build/" & name & " --mm:refc " & extra_params & " " &
    srcDir & name & ".nim"

proc buildLibrary(outLibNameAndExt: string,
            name: string,
            srcDir = "./",
            extra_params = "",
            `type` = "static") =

  if not dirExists "build":
    mkDir "build"

  if `type` == "static":
    exec "nim c" & " --out:build/" & outLibNameAndExt &
      " --threads:on --app:staticlib --opt:size --noMain --mm:refc --header -d:metrics" &
      " --nimMainPrefix:libwaku -d:discv5_protocol_id=d5waku " &
      extra_params & " " & srcDir & name & ".nim"
  else:
    when defined(windows):
      exec "nim c" & " --out:build/" & outLibNameAndExt &
        " --threads:on --app:lib --opt:size --noMain --mm:refc --header -d:metrics" &
        " --nimMainPrefix:libwaku -d:discv5_protocol_id=d5waku " &
        extra_params & " " & srcDir & name & ".nim"
    else:
      exec "nim c" & " --out:build/" & outLibNameAndExt &
        " --threads:on --app:lib --opt:size --noMain --mm:refc --header -d:metrics" &
        " --nimMainPrefix:libwaku -d:discv5_protocol_id=d5waku " &
        extra_params & " " & srcDir & name & ".nim"

proc getArch(): string =
  let arch = getEnv("ARCH")
  if arch != "": return $arch
  let (archFromUname, _) = gorgeEx("uname -m")
  return $archFromUname

task libwakuDynamicWindows, "Generate bindings":
  let outLibNameAndExt = "libwaku.dll"
  let name = "libwaku"
  buildLibrary outLibNameAndExt,
    name, "library/",
    """-d:chronicles_line_numbers --warning:Deprecated:off --warning:UnusedImport:on -d:chronicles_log_level=TRACE """,
    "dynamic"

task libwakuDynamicLinux, "Generate bindings":
  let outLibNameAndExt = "libwaku.so"
  let name = "libwaku"
  buildLibrary outLibNameAndExt,
    name, "library/",
    """-d:chronicles_line_numbers --warning:Deprecated:off --warning:UnusedImport:on -d:chronicles_log_level=TRACE """,
    "dynamic"

task libwakuDynamicMac, "Generate bindings":
  let outLibNameAndExt = "libwaku.dylib"
  let name = "libwaku"

  let arch = getArch()
  let sdkPath = staticExec("xcrun --show-sdk-path").strip()
  let archFlags = (if arch == "arm64": "--cpu:arm64 --passC:\"-arch arm64\" --passL:\"-arch arm64\" --passC:\"-isysroot " & sdkPath & "\" --passL:\"-isysroot " & sdkPath & "\""
                   else: "--cpu:amd64 --passC:\"-arch x86_64\" --passL:\"-arch x86_64\" --passC:\"-isysroot " & sdkPath & "\" --passL:\"-isysroot " & sdkPath & "\"")
  buildLibrary outLibNameAndExt,
    name, "library/",
    archFlags & " -d:chronicles_line_numbers --warning:Deprecated:off --warning:UnusedImport:on -d:chronicles_log_level=TRACE",
    "dynamic"

task libwakuStaticWindows, "Generate bindings":
  let outLibNameAndExt = "libwaku.lib"
  let name = "libwaku"
  buildLibrary outLibNameAndExt,
    name, "library/",
    """-d:chronicles_line_numbers --warning:Deprecated:off --warning:UnusedImport:on -d:chronicles_log_level=TRACE """,
    "static"

task libwakuStaticLinux, "Generate bindings":
  let outLibNameAndExt = "libwaku.a"
  let name = "libwaku"
  buildLibrary outLibNameAndExt,
    name, "library/",
    """-d:chronicles_line_numbers --warning:Deprecated:off --warning:UnusedImport:on -d:chronicles_log_level=TRACE """,
    "static"

task libwakuStaticMac, "Generate bindings":
  let outLibNameAndExt = "libwaku.a"
  let name = "libwaku"

  let arch = getArch()
  let sdkPath = staticExec("xcrun --show-sdk-path").strip()
  let archFlags = (if arch == "arm64": "--cpu:arm64 --passC:\"-arch arm64\" --passL:\"-arch arm64\" --passC:\"-isysroot " & sdkPath & "\" --passL:\"-isysroot " & sdkPath & "\""
                   else: "--cpu:amd64 --passC:\"-arch x86_64\" --passL:\"-arch x86_64\" --passC:\"-isysroot " & sdkPath & "\" --passL:\"-isysroot " & sdkPath & "\"")
  buildLibrary outLibNameAndExt,
    name, "library/",
    archFlags & " -d:chronicles_line_numbers --warning:Deprecated:off --warning:UnusedImport:on -d:chronicles_log_level=TRACE",
    "static"

proc buildMobileAndroid(srcDir = ".", params = "") =
  let cpu = getEnv("CPU")
  let abiDir = getEnv("ABIDIR")

  let outDir = "build/android/" & abiDir
  if not dirExists outDir:
    mkDir outDir

  var extra_params = params
  for i in 2 ..< paramCount():
    extra_params &= " " & paramStr(i)

  exec "nim c" & " --out:" & outDir &
    "/libwaku.so --threads:on --app:lib --opt:size --noMain --mm:refc -d:chronicles_sinks=textlines[dynamic] --header -d:chronosEventEngine=epoll --passL:-L" &
    outdir & " --passL:-lrln --passL:-llog --cpu:" & cpu & " --os:android -d:androidNDK " &
    extra_params & " " & srcDir & "/libwaku.nim"

proc test(name: string, params = "-d:chronicles_log_level=DEBUG", lang = "c") =
  # XXX: When running `> NIM_PARAMS="-d:chronicles_log_level=INFO" make test2`
  # I expect compiler flag to be overridden, however it stays with whatever is
  # specified here.
  buildBinary name, "tests/", params
  exec "build/" & name

### Waku common tasks
task testcommon, "Build & run common tests":
  test "all_tests_common", "-d:chronicles_log_level=WARN -d:chronosStrictException"

### Waku tasks
task wakunode2, "Build Waku v2 cli node":
  let name = "wakunode2"
  buildBinary name, "apps/wakunode2/", " -d:chronicles_log_level='TRACE' "

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
    "-d:chronicles_sinks=textlines[file] -d:chronicles_log_level='TRACE' "
  #  -d:ssl - cause unlisted exception error in libp2p/utility...

task chat2mix, "Build example Waku chat mix usage":
  # NOTE For debugging, set debug level. For chat usage we want minimal log
  # output to STDOUT. Can be fixed by redirecting logs to file (e.g.)
  #buildBinary name, "examples/", "-d:chronicles_log_level=WARN"

  let name = "chat2mix"
  buildBinary name,
    "apps/chat2mix/",
    "-d:chronicles_sinks=textlines[file] -d:chronicles_log_level='TRACE' "
  #  -d:ssl - cause unlisted exception error in libp2p/utility...

task chat2bridge, "Build chat2bridge":
  let name = "chat2bridge"
  buildBinary name, "apps/chat2bridge/"

task liteprotocoltester, "Build liteprotocoltester":
  let name = "liteprotocoltester"
  buildBinary name, "apps/liteprotocoltester/"

task lightpushwithmix, "Build lightpushwithmix":
  let name = "lightpush_publisher_mix"
  buildBinary name, "examples/lightpush_mix/"

task api_example, "Build api_example":
  let name = "api_example"
  buildBinary name, "examples/api_example/"

task buildone, "Build custom target":
  let filepath = paramStr(paramCount())
  discard buildModule filepath

task buildTest, "Test custom target":
  let filepath = paramStr(paramCount())
  discard buildModule(filepath)

import std/strutils

task execTest, "Run test":
  # Expects to be parameterized with test case name in quotes
  # preceded with the nim source file name and path
  # If no test case name is given still it requires empty quotes `""`
  let filepath = paramStr(paramCount() - 1)
  var testSuite = paramStr(paramCount()).strip(chars = {'\"'})
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

task libwakuStatic, "Build the cbindings waku node library":
  let lib_name = paramStr(paramCount())
  buildLibrary lib_name, "library/", chroniclesParams, "static"

task libwakuDynamic, "Build the cbindings waku node library":
  let lib_name = paramStr(paramCount())
  buildLibrary lib_name, "library/", chroniclesParams, "dynamic"

### Mobile Android
task libWakuAndroid, "Build the mobile bindings for Android":
  let srcDir = "./library"
  let extraParams = "-d:chronicles_log_level=ERROR"
  buildMobileAndroid srcDir, extraParams

### Mobile iOS
import std/sequtils

proc buildMobileIOS(srcDir = ".", params = "") =
  echo "Building iOS libwaku library"

  let iosArch = getEnv("IOS_ARCH")
  let iosSdk = getEnv("IOS_SDK")
  let sdkPath = getEnv("IOS_SDK_PATH")

  if sdkPath.len == 0:
    quit "Error: IOS_SDK_PATH not set. Set it to the path of the iOS SDK"

  # Get nimble package paths
  let bearsslPath = gorge("nimble path bearssl").strip()
  let secp256k1Path = gorge("nimble path secp256k1").strip()
  let natTraversalPath = gorge("nimble path nat_traversal").strip()

  # Get Nim standard library path
  let nimPath = gorge("nim --fullhelp 2>&1 | head -1 | sed 's/.*\\[//' | sed 's/\\].*//'").strip()
  let nimLibPath = nimPath.parentDir.parentDir / "lib"

  # Use SDK name in path to differentiate device vs simulator
  let outDir = "build/ios/" & iosSdk & "-" & iosArch
  if not dirExists outDir:
    mkDir outDir

  var extra_params = params
  for i in 2 ..< paramCount():
    extra_params &= " " & paramStr(i)

  let cpu = if iosArch == "arm64": "arm64" else: "amd64"

  # The output static library
  let nimcacheDir = outDir & "/nimcache"
  let objDir = outDir & "/obj"
  let vendorObjDir = outDir & "/vendor_obj"
  let aFile = outDir & "/libwaku.a"

  if not dirExists objDir:
    mkDir objDir
  if not dirExists vendorObjDir:
    mkDir vendorObjDir

  let clangBase = "clang -arch " & iosArch & " -isysroot " & sdkPath &
      " -mios-version-min=18.0 -fembed-bitcode -fPIC -O2"

  # Generate C sources from Nim (no linking)
  exec "nim c" &
      " --nimcache:" & nimcacheDir &
      " --os:ios --cpu:" & cpu &
      " --compileOnly:on" &
      " --noMain --mm:refc" &
      " --threads:on --opt:size --header" &
      " -d:metrics -d:discv5_protocol_id=d5waku" &
      " --nimMainPrefix:libwaku --skipParentCfg:on" &
      " --cc:clang" &
      " " & extra_params &
      " " & srcDir & "/libwaku.nim"

  # Compile vendor C libraries for iOS

  # --- BearSSL ---
  echo "Compiling BearSSL for iOS..."
  let bearSslSrcDir = bearsslPath / "bearssl/csources/src"
  let bearSslIncDir = bearsslPath / "bearssl/csources/inc"
  for path in walkDirRec(bearSslSrcDir):
    if path.endsWith(".c"):
      let relPath = path.replace(bearSslSrcDir & "/", "").replace("/", "_")
      let baseName = relPath.changeFileExt("o")
      let oFile = vendorObjDir / ("bearssl_" & baseName)
      if not fileExists(oFile):
        exec clangBase & " -I" & bearSslIncDir & " -I" & bearSslSrcDir & " -c " & path & " -o " & oFile

  # --- secp256k1 ---
  echo "Compiling secp256k1 for iOS..."
  let secp256k1Dir = secp256k1Path / "vendor/secp256k1"
  let secp256k1Flags = " -I" & secp256k1Dir & "/include" &
        " -I" & secp256k1Dir & "/src" &
        " -I" & secp256k1Dir &
        " -DENABLE_MODULE_RECOVERY=1" &
        " -DENABLE_MODULE_ECDH=1" &
        " -DECMULT_WINDOW_SIZE=15" &
        " -DECMULT_GEN_PREC_BITS=4"

  # Main secp256k1 source
  let secp256k1Obj = vendorObjDir / "secp256k1.o"
  if not fileExists(secp256k1Obj):
    exec clangBase & secp256k1Flags & " -c " & secp256k1Dir & "/src/secp256k1.c -o " & secp256k1Obj

  # Precomputed tables (required for ecmult operations)
  let secp256k1PreEcmultObj = vendorObjDir / "secp256k1_precomputed_ecmult.o"
  if not fileExists(secp256k1PreEcmultObj):
    exec clangBase & secp256k1Flags & " -c " & secp256k1Dir & "/src/precomputed_ecmult.c -o " & secp256k1PreEcmultObj

  let secp256k1PreEcmultGenObj = vendorObjDir / "secp256k1_precomputed_ecmult_gen.o"
  if not fileExists(secp256k1PreEcmultGenObj):
    exec clangBase & secp256k1Flags & " -c " & secp256k1Dir & "/src/precomputed_ecmult_gen.c -o " & secp256k1PreEcmultGenObj

  # --- miniupnpc ---
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
      exec clangBase &
          " -I" & miniupnpcIncDir &
          " -I" & miniupnpcSrcDir &
          " -I" & miniupnpcBuildDir &
          " -DMINIUPNPC_SET_SOCKET_TIMEOUT" &
          " -D_BSD_SOURCE -D_DEFAULT_SOURCE" &
          " -c " & srcPath & " -o " & oFile

  # --- libnatpmp ---
  echo "Compiling libnatpmp for iOS..."
  let natpmpSrcDir = natTraversalPath / "vendor/libnatpmp-upstream"
  # Only compile natpmp.c - getgateway.c uses net/route.h which is not available on iOS
  let natpmpObj = vendorObjDir / "natpmp_natpmp.o"
  if not fileExists(natpmpObj):
    exec clangBase &
        " -I" & natpmpSrcDir &
        " -DENABLE_STRNATPMPERR" &
        " -c " & natpmpSrcDir & "/natpmp.c -o " & natpmpObj

  # Use iOS-specific stub for getgateway
  let getgatewayStubSrc = "./library/ios_natpmp_stubs.c"
  let getgatewayStubObj = vendorObjDir / "natpmp_getgateway_stub.o"
  if fileExists(getgatewayStubSrc) and not fileExists(getgatewayStubObj):
    exec clangBase & " -c " & getgatewayStubSrc & " -o " & getgatewayStubObj

  # --- BearSSL stubs (for tools functions not in main library) ---
  echo "Compiling BearSSL stubs for iOS..."
  let bearSslStubsSrc = "./library/ios_bearssl_stubs.c"
  let bearSslStubsObj = vendorObjDir / "bearssl_stubs.o"
  if fileExists(bearSslStubsSrc) and not fileExists(bearSslStubsObj):
    exec clangBase & " -c " & bearSslStubsSrc & " -o " & bearSslStubsObj

  # Compile all Nim-generated C files to object files
  echo "Compiling Nim-generated C files for iOS..."
  var cFiles: seq[string] = @[]
  for kind, path in walkDir(nimcacheDir):
    if kind == pcFile and path.endsWith(".c"):
      cFiles.add(path)

  for cFile in cFiles:
    let baseName = extractFilename(cFile).changeFileExt("o")
    let oFile = objDir / baseName
    exec clangBase &
        " -DENABLE_STRNATPMPERR" &
        " -I" & nimLibPath &
        " -I" & bearsslPath & "/bearssl/csources/inc/" &
        " -I" & bearsslPath & "/bearssl/csources/tools/" &
        " -I" & bearsslPath & "/bearssl/abi/" &
        " -I" & secp256k1Path & "/vendor/secp256k1/include/" &
        " -I" & natTraversalPath & "/vendor/miniupnp/miniupnpc/include/" &
        " -I" & natTraversalPath & "/vendor/libnatpmp-upstream/" &
        " -I" & nimcacheDir &
        " -c " & cFile &
        " -o " & oFile

  # Create static library from all object files
  echo "Creating static library..."
  var objFiles: seq[string] = @[]
  for kind, path in walkDir(objDir):
    if kind == pcFile and path.endsWith(".o"):
      objFiles.add(path)
  for kind, path in walkDir(vendorObjDir):
    if kind == pcFile and path.endsWith(".o"):
      objFiles.add(path)

  exec "libtool -static -o " & aFile & " " & objFiles.join(" ")

  echo "iOS library created: " & aFile

task libWakuIOS, "Build the mobile bindings for iOS":
  let srcDir = "./library"
  let extraParams = "-d:chronicles_log_level=ERROR"
  buildMobileIOS srcDir, extraParams

task liblogosdeliveryStatic, "Build the liblogosdelivery (Logos Messaging Delivery API) static library":
  let lib_name = paramStr(paramCount())
  buildLibrary lib_name, "liblogosdelivery/", chroniclesParams, "static", "liblogosdelivery.nim", "liblogosdelivery"

task liblogosdeliveryDynamic, "Build the liblogosdelivery (Logos Messaging Delivery API) dynamic library":
  let lib_name = paramStr(paramCount())
  buildLibrary lib_name, "liblogosdelivery/", chroniclesParams, "dynamic", "liblogosdelivery.nim", "liblogosdelivery"
