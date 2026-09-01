# Workaround for Nimble 0.24.1 lock handling when requirements use URLs.
# File-and-line references below refer to that Nimble version:
# https://github.com/nim-lang/nimble
#
# This script writes requires.generated, a supplemental requirements string
# passed to:
#
#   nimble setup --requires:"$(cat requires.generated)"
#
# Nimble matches lock entries by package name in solveLockFileDeps
# (src/nimblepkg/nimblesat.nim:1226). A URL requirement therefore may not
# receive the revision recorded under the package name in nimble.lock.
# This script derives additional constraints from the lock. It does not
# guarantee which revision Nimble selects; scripts/audit_deps.nims checks
# the installed metadata after setup.
#
# Inputs:
# - nimble.lock supplies the expected package name, version, repository
#   URL, and VCS revision.
# - logos_delivery.nimble supplies explicit URL requirements. The generator
#   omits matching URLs rather than adding a second root constraint.
# - The configured registry mirrors supply the current name-to-URL mapping.
# - `git ls-remote --tags` supplies the current tag refs for each
#   repository.
#
# Emission rule for each git lock entry not already required by URL:
# - registry URL matches and the version tag points to the locked revision:
#     "name == version"
# - either condition does not match:
#     "url#revision"
#
# Known limitation: Nimble 0.24.1 can normalize a `url#revision`
# requirement together with a competing name requirement and retain the
# other special version. The post-setup audit rejects the result when its
# recorded vcsRevision differs from nimble.lock.
#
# The script also compares the normalized repository URL and revision
# mappings in nimble.lock and nix/deps.nix in both directions for the git
# dependencies it processes. A missing URL or differing revision causes a
# nonzero exit. Registry-fetch and tag-query failures also cause a nonzero
# exit.
#
# Outputs:
# - requires.generated: written through a temporary path and rename only
#   after validation succeeds.
# - observed.generated: diagnostic output from the current invocation.
#   Build and setup rules do not consume this file. It may be written even
#   when a later validation error causes the invocation to fail.

import std/[json, strutils, algorithm, sets, tables]

let root = thisDir() & "/.."

const registryMirrors = [
  "https://raw.githubusercontent.com/nim-lang/packages/master/packages.json",
  "https://packages.nim-lang.org/packages.json",
]

const nixHint = "regenerate with: tools/gen-nix-deps.sh nimble.lock nix/deps.nix"

proc normUrl(url: string): string =
  result = url.toLowerAscii()
  result.removeSuffix("/")
  result.removeSuffix(".git")

# Return normalized base URLs from quoted URL requirements on non-comment
# lines. A fragment or version constraint terminates the base URL.
proc urlPinsFrom(content: string): HashSet[string] =
  for line in content.splitLines():
    if line.strip(trailing = false).startsWith("#"):
      continue
    let parts = line.split('"')
    var i = 1
    while i < parts.len:
      if parts[i].startsWith("http://") or parts[i].startsWith("https://"):
        var base = parts[i]
        let cut = min(
          if base.find('#') >= 0: base.find('#') else: base.len,
          if base.find(' ') >= 0: base.find(' ') else: base.len,
        )
        base = base[0 ..< cut]
        result.incl(normUrl(base))
      i += 2

proc nimbleUrlPins(path: string): HashSet[string] =
  urlPinsFrom(readFile(path))

# Map normalized repository URLs to revisions from fetchgit blocks in
# nix/deps.nix.
proc nixEntriesFrom(content: string): Table[string, string] =
  var url = ""
  for line in content.splitLines():
    let l = line.strip()
    if l.startsWith("url = \""):
      url = l.split('"')[1]
    elif l.startsWith("rev = \"") and url.len > 0:
      result[normUrl(url)] = l.split('"')[1]
      url = ""

proc nixEntries(path: string): Table[string, string] =
  nixEntriesFrom(readFile(path))

# Map lowercase package names to normalized repository URLs. Resolve one
# level of registry alias.
proc registryFrom(jsonContent: string): Table[string, string] =
  var byName = initTable[string, JsonNode]()
  for p in parseJson(jsonContent):
    if p.hasKey("name"):
      byName[p["name"].getStr().toLowerAscii()] = p
  for lname, p in byName:
    var entry = p
    if entry.hasKey("alias"):
      entry = byName.getOrDefault(entry["alias"].getStr().toLowerAscii(), newJObject())
    if entry.hasKey("url"):
      result[lname] = normUrl(entry["url"].getStr())

proc registryUrls(): Table[string, string] =
  var lastErr = ""
  for mirror in registryMirrors:
    let (output, code) = gorgeEx("curl -fsSL --max-time 60 " & mirror)
    if code != 0:
      lastErr = "curl exit " & $code & " for " & mirror
      continue
    return registryFrom(output)
  echo "gen_requires: cannot fetch the Nimble registry: " & lastErr
  quit(1)

# Return true when a plain tag or the peeled target of an annotated tag
# for `version` equals `rev`. The comparison uses complete ls-remote
# output lines. The git invocation below requests an abort when transfer
# speed remains below one byte per second for 60 seconds.
proc tagLineMatches(lsRemoteOutput, version, rev: string): bool =
  var expected: HashSet[string]
  for prefix in ["refs/tags/", "refs/tags/v"]:
    for suffix in ["", "^{}"]:
      expected.incl(rev & "\t" & prefix & version & suffix)
  for line in lsRemoteOutput.splitLines():
    if line in expected:
      return true
  return false

proc versionTagPointsAtRev(url, version, rev: string): bool =
  let (output, code) = gorgeEx(
    "git -c http.lowSpeedLimit=1 -c http.lowSpeedTime=60 ls-remote --tags " & url)
  if code != 0:
    raise newException(CatchableError, "git ls-remote --tags failed for " & url)
  tagLineMatches(output, version, rev)

proc writeAtomic(path, content: string) =
  writeFile(path & ".tmp", content)
  mvFile(path & ".tmp", path)

type LockEntry = tuple[name, version, rev, url: string]

proc main() =
  let lock = parseJson(readFile(root & "/nimble.lock"))["packages"]
  let inFile = nimbleUrlPins(root & "/logos_delivery.nimble")
  let nix = nixEntries(root & "/nix/deps.nix")
  let registry = registryUrls()

  var entries: seq[LockEntry]
  for name, e in lock:
    if name == "nim" or name == "nimble":
      continue
    if e{"downloadMethod"}.getStr() != "git":
      continue
    entries.add((name, e["version"].getStr(), e["vcsRevision"].getStr(),
                 e["url"].getStr()))
  entries.sort(proc(a, b: LockEntry): int = cmp(a.name, b.name))

  var errors: seq[string]
  var lockUrls: HashSet[string]
  for e in entries:
    lockUrls.incl(normUrl(e.url))
  var missing = inFile - lockUrls
  for u in missing:
    errors.add("logos_delivery.nimble pins " & u &
               ", but nimble.lock has no entry for it")

  for url, _ in nix:
    if url notin lockUrls:
      errors.add("nix/deps.nix has " & url &
                 ", but nimble.lock has no entry for it (" & nixHint & ")")

  var candidates: seq[LockEntry]
  for e in entries:
    let url = normUrl(e.url)
    if url notin nix:
      errors.add(e.name & ": not in nix/deps.nix (" & nixHint & ")")
      continue
    if nix[url] != e.rev:
      errors.add(e.name & ": nimble.lock has " & e.rev &
                 ", nix/deps.nix has " & nix[url])
    if url in inFile:
      continue
    candidates.add(e)

  var outParts: seq[string]
  var record = @[
    "# Diagnostic output from the most recent gen_requires.nims invocation.",
    "# Not consumed by dependency setup or build rules.",
  ]
  for e in candidates:
    let inRegistry = registry.getOrDefault(e.name.toLowerAscii(), "") == normUrl(e.url)
    var usable = false
    if inRegistry:
      try:
        usable = versionTagPointsAtRev(e.url, e.version, e.rev)
      except CatchableError as ex:
        errors.add(e.name & ": observation failed: " & ex.msg)
        record.add(e.name & " " & e.rev & " observation-failed")
        continue
    let taggedCol = if inRegistry: $ord(usable) else: "-"
    record.add(e.name & " " & e.rev & " tagged=" & taggedCol &
               " registry=" & $ord(inRegistry))
    if usable:
      outParts.add(e.name & " == " & e.version)
    else:
      var base = e.url
      base.removeSuffix("/")
      base.removeSuffix(".git")
      outParts.add(base & "#" & e.rev)

  writeAtomic(root & "/observed.generated", record.join("\n") & "\n")

  if errors.len > 0:
    for e in errors:
      echo "gen_requires: " & e
    quit(1)

  let requires = outParts.join("; ")
  writeAtomic(root & "/requires.generated", requires & "\n")
  echo requires

#---------------------------------------------------------------------
# Self-tests for the parsing helpers. Executed before main().
#---------------------------------------------------------------------
proc selfTest() =
  # Cover a mixed-case owner and the optional ".git" suffix.
  doAssert normUrl("https://github.com/NagyZoltanPeter/nim-brokers.git") ==
    "https://github.com/nagyzoltanpeter/nim-brokers"
  doAssert normUrl("https://github.com/vacp2p/nim-boringssl") ==
    "https://github.com/vacp2p/nim-boringssl"
  # A package name that starts with "http" is not a URL requirement.
  doAssert urlPinsFrom("""  "httputils >= 0.4.1",""").len == 0
  # A comment line is not a requirement, also when it quotes a URL.
  doAssert urlPinsFrom("""# v2.0.0: "https://github.com/vacp2p/nim-libp2p"""").len == 0
  doAssert "https://github.com/vacp2p/nim-libp2p" in urlPinsFrom(
    """requires "https://github.com/vacp2p/nim-libp2p.git#c43199378f46d0aaf61be1cad1ee1d63e8f665d6"""")
  doAssert "https://github.com/vacp2p/nim-lsquic" in urlPinsFrom(
    """requires "https://github.com/vacp2p/nim-lsquic.git == 0.5.1"""")
  let nix = nixEntriesFrom("""
  chronos = pkgs.fetchgit {
    url = "https://github.com/status-im/nim-chronos";
    rev = "45f43a9ad8bd8bcf5903b42f365c1c879bd54240";
    sha256 = "sha256-000";
    fetchSubmodules = true;
  };
""")
  doAssert nix["https://github.com/status-im/nim-chronos"] ==
    "45f43a9ad8bd8bcf5903b42f365c1c879bd54240"
  # These tag lines were captured from the referenced repositories: a
  # plain tag, then the peeled target of an annotated tag.
  doAssert tagLineMatches(
    "c43199378f46d0aaf61be1cad1ee1d63e8f665d6\trefs/tags/v2.0.0",
    "2.0.0", "c43199378f46d0aaf61be1cad1ee1d63e8f665d6")
  doAssert tagLineMatches(
    "19565dd80621e33f6da396ef3fb07c379d55c324\trefs/tags/v3.3.0^{}",
    "3.3.0", "19565dd80621e33f6da396ef3fb07c379d55c324")
  # A tag that points at a different revision does not match.
  doAssert not tagLineMatches(
    "f44cff901dff2a24fedcf4ef9e12a6f72355d58f\trefs/tags/v0.6.0",
    "0.6.0", "d8f1288b7c72f00be5fc2c5ea72bf5cae1eafb15")
  # Registry parsing: names compare case-insensitively, an alias is
  # followed one level, and an alias to a missing entry yields nothing.
  let reg = registryFrom("""[
    {"name": "Chronos", "url": "https://github.com/status-im/nim-chronos"},
    {"name": "old", "alias": "chronos"},
    {"name": "dead", "alias": "gone"}
  ]""")
  doAssert reg["chronos"] == "https://github.com/status-im/nim-chronos"
  doAssert reg["old"] == "https://github.com/status-im/nim-chronos"
  doAssert "dead" notin reg

selfTest()
main()
