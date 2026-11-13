#!fmt: off

import std/[os, strutils]
mode = ScriptMode.Verbose

### Package
version = "0.40.0"
author = "Status Research & Development GmbH"
description = "Logos-delivery, Private P2P Messaging for Resource-Restricted Devices"
license = "MIT or Apache License 2.0"
skipDirs = @["tests", "examples", "apps", "simulations", "metrics"]

# Nimble installs only the namesake directory; dependents need these too.
installDirs = @["library", "migrations", "rest", "tools"]

const RequiredNimblePin = "0.26.0"
  ## The Nimble release the build installs.

### Dependencies
# Only Nim 2.2.6 is tested; newer releases are accepted for callers that pin their own.
requires "nim >= 2.2.6",
  # 4.4.0 plus the shutdown API that nim-ffi and nim-brokers use. No release
  # tag has it: v4.4.1 was cut before it. A URL pin does not hold here, the
  # solver keeps the name node on the newest tag.
  "chronos#0de7b335d0ad5557ad5ba71a4b7662f7b201750e",
  "taskpools",
  # Logging & Configuration
  "chronicles",
  "confutils",
  # Serialization
  "serialization",
  "json_serialization",
  "toml_serialization",
  "protobuf_serialization",
  "faststreams",
  # Networking & P2P
  "libp2p == 2.4.1",
  # 0.9.0 is the locked version; an unversioned "eth" resolves to nim-eth HEAD,
  # which no longer ships eth/p2p/discoveryv5/enr.
  "eth == 0.9.0",
  # nat_traversal is in the graph only through eth: its eth/net/nat imports it,
  # and nothing here imports that.
  "dnsdisc",
  "dnsclient",
  "httputils >= 0.4.1",
  # v0.4.1: libp2p 2.4.0 requires websock >= 0.4.1 and locks this version.
  "https://github.com/status-im/nim-websock#0432dc445c500b20963ef4b76e585c1a3943c254",
  # Cryptography
  "nimcrypto >= 0.7.3",
  "secp256k1 >= 0.8.0.8.0",
  # 0.2.14 writes into the read-only nix store when cross-building for Windows.
  "bearssl == 0.2.13",
  # RPC & APIs
  "json_rpc == 0.7.0",
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
  # eth requires snappy by name; its HEAD needs testutils >= 0.8.5, which
  # contradicts the testutils pin below. This is the locked revision.
  "https://github.com/status-im/nim-snappy#a99d113197e81bf764a3b005b0ade3f9f3758069",
  "testutils == 0.8.1",
  "unittest2"

# URL requirements described above.
# For commit-pinned releases, the preceding link records the associated
# upstream release tag at the time the revision was selected.

requires "https://github.com/logos-messaging/nim-ffi#d98f77141de9c95c0c543d191a79aee18e7536a4"

# No tag at pinning time; revision was 19 commits after v0.3.1-rc.0.
requires "https://github.com/logos-messaging/nim-sds.git#4b08d508dbfa69c0e2e3883db67adf1fe5a0c994"

# v3.4.0: https://github.com/NagyZoltanPeter/nim-brokers/releases/tag/v3.4.0
requires "https://github.com/NagyZoltanPeter/nim-brokers.git#fd97eb355eee5d14594e0b4599964eff00648ec7"

requires "https://github.com/logos-messaging/nim-segmentation#0593ef7c9267b0204093fe202bec477b2dbf824c"

requires "https://github.com/status-im/nim-leopard#3a24aa1f4b7ce227e8d30c51357ae241cf6b478d"

# v0.9.0: https://github.com/vacp2p/nim-lsquic/releases/tag/v0.9.0
# libp2p requires "lsquic >= 0.9.0" by name. The exact numeric constraint
# keeps the resolution at the validated release instead of floating to
# the newest one.
requires "https://github.com/vacp2p/nim-lsquic#fb293834a3f90368e1f6c57aec2360cf8d840c5a"

# No tag at pinning time; revision was one commit after v0.2.0.
requires "https://github.com/vacp2p/nim-jwt.git#057ec95eb5af0eea9c49bfe9025b3312c95dc5f2"

# Pin the Mix and shared RLN adapter integration revisions.
requires "https://github.com/logos-co/nim-libp2p-mix#fe620629bb40b2212d86e158da5929bbedfcb957"
requires "https://github.com/logos-co/mix-rln-spam-protection-plugin#7b5c7cfafbffe4e47aeb46838633645afacdb73c"

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

  selfExec "c --out:build/" & filepath & ".bin --mm:refc " & getMyCPU() & " " & params & getNimParams() &
    " " & filePath

  # exec will raise exception if anything goes wrong
  return true

proc buildBinary(name: string, srcDir = "./", params = "") =
  if not dirExists "build":
    mkDir "build"
  selfExec "c --out:build/" & name & " --mm:refc " & getMyCPU() & " " & params & getNimParams() & " " &
    srcDir & name & ".nim"

proc test(name: string, params = "-d:chronicles_log_level=INFO") =
  buildBinary name, "tests/", params
  exec "build/" & name

### Waku common tasks
task testcommon, "Build & run common tests":
  test "all_tests_common"

### Waku tasks
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

task rlnkeystore, "Build the RLN keystore generator":
  let name = "rlnkeystore"
  buildBinary name, "apps/rlnkeystore/"

task rln_db_inspector, "Build the rln db inspector":
  let name = "rln_db_inspector"
  buildBinary name, "tools/rln_db_inspector/"

task test, "Build & run Waku tests":
  test "all_tests_waku"

task testwakuext, "Build & run tests of what is built on the Waku protocols":
  test "all_tests_waku_ext"

task testapp, "Build & run node app tests":
  test "all_tests_app"

task testlogosdelivery, "Build & run Logos Delivery API layer tests":
  test "all_tests_logos_delivery"

task example2, "Build Waku examples":
  buildBinary "api_example", "examples/api_example/"
  buildBinary "channel_encryption_example", "examples/channel_encryption/"
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

### Formatting tasks

task auditdeps, "Check the installed packages against nimble.lock":
  # A task runs under the Nim that Nimble installs for the locked `nim` entry.
  selfExec "e --hints:off scripts/audit_deps.nims"

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
