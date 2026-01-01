#!fmt: off

import os
mode = ScriptMode.Verbose

### Package
version = "0.36.0"
author = "Status Research & Development GmbH"
description = "Waku, Private P2P Messaging for Resource-Restricted Devices"
license = "MIT or Apache License 2.0"
#bin           = @["build/waku"]

### Dependencies
requires "nim >= 2.2.4",
  "https://github.com/status-im/nim-chronicles.git#54f5b726025e8c7385e3a6529d3aa27454c6e6ff",
  "https://github.com/status-im/nim-confutils.git#e214b3992a31acece6a9aada7d0a1ad37c928f3b",
  "https://github.com/status-im/nim-chronos.git#0646c444fce7c7ed08ef6f2c9a7abfd172ffe655",
  "https://github.com/status-im/nim-dnsdisc.git#b71d029f4da4ec56974d54c04518bada00e1b623",
  "https://github.com/status-im/nim-eth.git#d9135e6c3c5d6d819afdfb566aa8d958756b73a8",
  "https://github.com/status-im/nim-json-rpc.git#9665c265035f49f5ff94bbffdeadde68e19d6221",
  "https://github.com/status-im/nim-libbacktrace.git#d8bd4ce5c46bb6d2f984f6b3f3d7380897d95ecb",
  "https://github.com/cheatfate/nimcrypto.git#721fb99ee099b632eb86dfad1f0d96ee87583774",
  "https://github.com/status-im/nim-serialization.git#6f525d5447d97256750ca7856faead03e562ed20",
  "https://github.com/status-im/nim-toml-serialization.git#fea85b27f0badcf617033ca1bc05444b5fd8aa7a",
  "https://github.com/status-im/nim-stew.git#e5740014961438610d336cd81706582dbf2c96f0",
  "https://github.com/status-im/nim-stint.git#470b7892561b5179ab20bd389a69217d6213fe58",
  "https://github.com/status-im/nim-metrics.git#ecf64c6078d1276d3b7d9b3d931fbdb70004db11",
  "https://github.com/vacp2p/nim-libp2p.git#e82080f7b1aa61c6d35fa5311b873f41eff4bb52",
  "https://github.com/status-im/nim-web3.git#81ee8ce479d86acb73be7c4f365328e238d9b4a3",
  "https://github.com/status-im/nim-presto.git#92b1c7ff141e6920e1f8a98a14c35c1fa098e3be",
  "https://github.com/nitely/nim-regex.git#4593305ed1e49731fc75af1dc572dd2559aad19c",
  "https://github.com/arnetheduck/nim-results.git#df8113dda4c2d74d460a8fa98252b0b771bf1f27",
  "https://github.com/nim-lang/db_connector.git#74aef399e5c232f95c9fc5c987cebac846f09d62",
  "https://github.com/status-im/nim-minilru.git#0c4b2bce959591f0a862e9b541ba43c6d0cf3476",
  "https://github.com/status-im/nim-unittest2.git#8b51e99b4a57fcfb31689230e75595f024543024",
  "https://github.com/status-im/nim-testutils.git#94d68e796c045d5b37cabc6be32d7bfa168f8857",
  "https://github.com/status-im/nim-bearssl.git#11e798b62b8e6beabe958e048e9e24c7e0f9ee63",
  "https://github.com/status-im/nim-secp256k1.git#9dd3df62124aae79d564da636bb22627c53c7676",
  "https://github.com/status-im/nim-nat-traversal.git#860e18c37667b5dd005b94c63264560c35d88004",
  "https://github.com/status-im/nim-faststreams.git#c3ac3f639ed1d62f59d3077d376a29c63ac9750c",
  "https://github.com/status-im/nim-http-utils.git#79cbab1460f4c0cdde2084589d017c43a3d7b4f1",
  "https://github.com/status-im/nim-json-serialization.git#b65fd6a7e64c864dabe40e7dfd6c7d07db0014ac",
  "https://github.com/status-im/nim-websock.git#ebe308a79a7b440a11dfbe74f352be86a3883508",
  "https://github.com/status-im/nim-zlib.git#daa8723fd32299d4ca621c837430c29a5a11e19a",
  "https://github.com/arnetheduck/nim-sqlite3-abi.git#bdf01cf4236fb40788f0733466cdf6708783cbac",
  "https://github.com/status-im/nim-taskpools.git#9e8ccc754631ac55ac2fd495e167e74e86293edb",
  "https://github.com/nitely/nim-unicodedb.git#66f2458710dc641dd4640368f9483c8a0ec70561",
  "https://github.com/ba0f3/dnsclient.nim.git#23214235d4784d24aceed99bbfe153379ea557c8"

### Helper functions

# Get nimble package paths for compilation
proc getNimblePkgDir(): string =
  # Get nimble's package directory
  when defined(windows):
    getEnv("USERPROFILE") / ".nimble" / "pkgs2"
  else:
    getEnv("HOME") / ".nimble" / "pkgs2"

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
  # Use nimble c command which automatically handles package paths
  # Add vendor/nim-ffi explicitly since it's a submodule
  let nimbleCmd = "nimble c --out:build/" & name & " --mm:refc --path:vendor/nim-ffi " & params & " " & srcDir & name & ".nim"
  exec nimbleCmd

proc buildLibrary(lib_name: string, srcDir = "./", params = "", `type` = "static") =
  if not dirExists "build":
    mkDir "build"
  # allow something like "nim nimbus --verbosity:0 --hints:off nimbus.nims"
  var extra_params = params
  for i in 2 ..< (paramCount() - 1):
    extra_params &= " " & paramStr(i)
  if `type` == "static":
    exec "nim c" & " --out:build/" & lib_name &
      " --threads:on --app:staticlib --opt:size --noMain --mm:refc --header -d:metrics --nimMainPrefix:libwaku --skipParentCfg:on -d:discv5_protocol_id=d5waku " &
      extra_params & " " & srcDir & "libwaku.nim"
  else:
    exec "nim c" & " --out:build/" & lib_name &
      " --threads:on --app:lib --opt:size --noMain --mm:refc --header -d:metrics --nimMainPrefix:libwaku --skipParentCfg:off -d:discv5_protocol_id=d5waku " &
      extra_params & " " & srcDir & "libwaku.nim"

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
    "/libwaku.so --threads:on --app:lib --opt:size --noMain --mm:refc -d:chronicles_sinks=textlines[dynamic] --header --passL:-L" &
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
  buildBinary "waku_example", "examples/"
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
    "-d:chronicles_sinks=textlines[file] -d:ssl -d:chronicles_log_level='TRACE' "

task chat2mix, "Build example Waku chat mix usage":
  # NOTE For debugging, set debug level. For chat usage we want minimal log
  # output to STDOUT. Can be fixed by redirecting logs to file (e.g.)
  #buildBinary name, "examples/", "-d:chronicles_log_level=WARN"

  let name = "chat2mix"
  buildBinary name,
    "apps/chat2mix/",
    "-d:chronicles_sinks=textlines[file] -d:ssl -d:chronicles_log_level='TRACE' "

task chat2bridge, "Build chat2bridge":
  let name = "chat2bridge"
  buildBinary name, "apps/chat2bridge/"

task liteprotocoltester, "Build liteprotocoltester":
  let name = "liteprotocoltester"
  buildBinary name, "apps/liteprotocoltester/"

task lightpushwithmix, "Build lightpushwithmix":
  let name = "lightpush_publisher_mix"
  buildBinary name, "examples/lightpush_mix/"

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

# Helper to get nimble package path
proc getNimblePkgPath(pkgName: string): string =
  let (output, exitCode) = gorgeEx("nimble path " & pkgName)
  if exitCode != 0:
    quit "Error: Could not find nimble package: " & pkgName
  result = output.strip()

# Helper to get Nim lib path
proc getNimLibPath(): string =
  let (output, exitCode) = gorgeEx("nim --verbosity:0 --hints:off dump --dump.format:json 2>/dev/null | grep -o '\"libpath\":\"[^\"]*\"' | cut -d'\"' -f4")
  if exitCode != 0 or output.strip().len == 0:
    # Fallback: try to find it relative to nim binary
    let (nimPath, _) = gorgeEx("which nim")
    result = nimPath.strip().parentDir().parentDir() / "lib"
  else:
    result = output.strip()

proc buildMobileIOS(srcDir = ".", params = "") =
  echo "Building iOS libwaku library"

  let iosArch = getEnv("IOS_ARCH")
  let iosSdk = getEnv("IOS_SDK")
  let sdkPath = getEnv("IOS_SDK_PATH")

  if sdkPath.len == 0:
    quit "Error: IOS_SDK_PATH not set. Set it to the path of the iOS SDK"

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

  # Get nimble package paths
  let bearSslPkgDir = getNimblePkgPath("bearssl")
  let secp256k1PkgDir = getNimblePkgPath("secp256k1")
  let natTraversalPkgDir = getNimblePkgPath("nat_traversal")
  let nimLibDir = getNimLibPath()

  # Compile C libraries for iOS

  # --- BearSSL ---
  echo "Compiling BearSSL for iOS..."
  let bearSslSrcDir = bearSslPkgDir / "bearssl/csources/src"
  let bearSslIncDir = bearSslPkgDir / "bearssl/csources/inc"
  for path in walkDirRec(bearSslSrcDir):
    if path.endsWith(".c"):
      let relPath = path.replace(bearSslSrcDir & "/", "").replace("/", "_")
      let baseName = relPath.changeFileExt("o")
      let oFile = vendorObjDir / ("bearssl_" & baseName)
      if not fileExists(oFile):
        exec clangBase & " -I" & bearSslIncDir & " -I" & bearSslSrcDir & " -c " & path & " -o " & oFile

  # --- secp256k1 ---
  echo "Compiling secp256k1 for iOS..."
  let secp256k1Dir = secp256k1PkgDir / "vendor/secp256k1"
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
  let miniupnpcSrcDir = natTraversalPkgDir / "vendor/miniupnp/miniupnpc/src"
  let miniupnpcIncDir = natTraversalPkgDir / "vendor/miniupnp/miniupnpc/include"
  let miniupnpcBuildDir = natTraversalPkgDir / "vendor/miniupnp/miniupnpc/build"
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
  let natpmpSrcDir = natTraversalPkgDir / "vendor/libnatpmp-upstream"
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
        " -I" & nimLibDir & "/" &
        " -I" & bearSslPkgDir & "/bearssl/csources/inc/" &
        " -I" & bearSslPkgDir & "/bearssl/csources/tools/" &
        " -I" & bearSslPkgDir & "/bearssl/abi/" &
        " -I" & secp256k1PkgDir & "/vendor/secp256k1/include/" &
        " -I" & natTraversalPkgDir & "/vendor/miniupnp/miniupnpc/include/" &
        " -I" & natTraversalPkgDir & "/vendor/libnatpmp-upstream/" &
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

  echo "✔ iOS library created: " & aFile

task libWakuIOS, "Build the mobile bindings for iOS":
  let srcDir = "./library"
  let extraParams = "-d:chronicles_log_level=ERROR"
  buildMobileIOS srcDir, extraParams
