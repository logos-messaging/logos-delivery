# Checks the installed packages against nimble.lock: every lock entry must be
# present at its vcsRevision, and nothing else may be installed. `nim` is
# skipped (--useSystemNim). The script reads files, writes nothing and exits 1
# on any problem.
#
#   nim e scripts/audit_deps.nims
#
# `nimble setup` does not remove stale directories: after dropping a package,
# delete nimbledeps/ before setup.

import std/[json, strutils, algorithm, sets]

let root = thisDir() & "/.."

proc normUrl(url: string): string =
  result = url.toLowerAscii()
  result.removeSuffix("/")
  result.removeSuffix(".git")

# Reads a nimblemeta.json field, top-level or under metaData.
proc metaField(meta: JsonNode, field: string): string =
  if meta.hasKey(field):
    return meta[field].getStr()
  return meta{"metaData", field}.getStr()

type Installed = tuple[dir, url, rev: string]

# Finds the directory for a lock entry: the one at the locked revision, else
# any at the same URL.
proc findInstalled(inst: seq[Installed], url, rev: string): int =
  for i, p in inst:
    if p.url == url and p.rev == rev: return i
  for i, p in inst:
    if p.url == url: return i
  -1

proc installedMismatches(lock: JsonNode, pkgs2: string, ok: var int, total: var int): seq[string] =
  var inst: seq[Installed]
  var metaless: seq[string]
  for path in listDirs(pkgs2):
    let d = path.split('/')[^1]
    let metaPath = path & "/nimblemeta.json"
    if not fileExists(metaPath):
      metaless.add(d)
      continue
    let meta = parseJson(readFile(metaPath))
    inst.add((d, normUrl(metaField(meta, "url")), metaField(meta, "vcsRevision")))

  var names: seq[string]
  for name, _ in lock:
    names.add(name)
  names.sort()

  var matchedDirs: HashSet[string]
  for name in names:
    if name == "nim":
      continue
    total += 1
    let entry = lock[name]
    let want = entry["vcsRevision"].getStr()
    let i = findInstalled(inst, normUrl(entry["url"].getStr()), want)
    if i < 0:
      result.add(name & ": in nimble.lock but not installed")
      continue
    matchedDirs.incl(inst[i].dir)
    if inst[i].rev != want:
      result.add(name & ": lock has " & want & ", installed " & inst[i].dir & " has " & inst[i].rev)
    else:
      ok += 1

  # Report the installed directories that match no lock entry.
  var dirs: seq[string]
  for p in inst:
    dirs.add(p.dir)
  dirs.sort()
  for d in dirs:
    if d notin matchedDirs:
      result.add(d & ": installed but not in nimble.lock")
  metaless.sort()
  for d in metaless:
    result.add(d & ": installed without nimblemeta.json")

proc main() =
  let lock = parseJson(readFile(root & "/nimble.lock"))["packages"]
  let pkgs2 = root & "/nimbledeps/pkgs2"

  var bad: seq[string]
  var ok = 0
  var total = 0
  if not dirExists(pkgs2):
    bad.add("no nimbledeps/pkgs2 directory; run setup first")
  else:
    bad.add installedMismatches(lock, pkgs2, ok, total)

  for b in bad:
    echo "audit: " & b
  if bad.len > 0:
    echo "audit: " & $bad.len & " problem(s) found"
    quit(1)
  echo "audit: " & $ok & "/" & $total & " installed packages match nimble.lock"

# The self-tests run before main().
proc selfTest() =
  doAssert normUrl("https://github.com/NagyZoltanPeter/nim-brokers.git") ==
    "https://github.com/nagyzoltanpeter/nim-brokers"
  doAssert metaField(parseJson(
    """{"vcsRevision": "d34aa46bf9d0a3ffff810fbd3c4d2fa024eb9368"}"""),
    "vcsRevision") == "d34aa46bf9d0a3ffff810fbd3c4d2fa024eb9368"
  doAssert metaField(parseJson(
    """{"metaData": {"vcsRevision": "d34aa46bf9d0a3ffff810fbd3c4d2fa024eb9368"}}"""),
    "vcsRevision") == "d34aa46bf9d0a3ffff810fbd3c4d2fa024eb9368"
  doAssert metaField(parseJson("""{}"""), "vcsRevision") == ""

  # With two installed directories for one URL, the one at the locked revision matches.
  let two: seq[Installed] = @[("chronos-4.2.4-aaaa", "https://github.com/status-im/nim-chronos", "90f5"),
                              ("chronos-4.2.5-bbbb", "https://github.com/status-im/nim-chronos", "0ab8")]
  doAssert two[findInstalled(two, "https://github.com/status-im/nim-chronos", "0ab8")].dir == "chronos-4.2.5-bbbb"
  doAssert two[findInstalled(two, "https://github.com/status-im/nim-chronos", "90f5")].dir == "chronos-4.2.4-aaaa"
  doAssert two[findInstalled(two, "https://github.com/status-im/nim-chronos", "ffff")].url.len > 0
  doAssert findInstalled(two, "https://github.com/status-im/nim-stew", "x") == -1

selfTest()
main()
