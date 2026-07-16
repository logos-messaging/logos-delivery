## Install nimble.lock packages into nimbledeps/pkgs2 and write nimble.paths.
##
## Used when `nimble setup --localdeps` fails (e.g. SAT cannot resolve libp2p
## git pins). Reproducible: clones exact vcsRevision from the lockfile.
##
## Usage (from repo root):
##   nim c -r --hints:off tools/install_from_lock.nim
##
## Optional env:
##   INSTALL_FROM_LOCK_FORCE=1  re-clone packages even if present

import std/[json, os, osproc, strutils, algorithm]

const
  PkgsRel = "nimbledeps" / "pkgs2"
  LockRel = "nimble.lock"
  PathsRel = "nimble.paths"

proc run(cmd: string): int =
  execCmd(cmd)

proc runOut(cmd: string): tuple[output: string, exitCode: int] =
  execCmdEx(cmd)

proc gitClone(url, dest, rev: string): bool =
  if dirExists(dest):
    removeDir(dest)
  # Shallow clone of a specific commit is awkward; full clone then checkout.
  var c = run("git clone --quiet " & quoteShell(url) & " " & quoteShell(dest))
  if c != 0:
    let url2 = url.replace(".git", "")
    c = run("git clone --quiet " & quoteShell(url2) & " " & quoteShell(dest))
    if c != 0:
      return false
  if run("git -C " & quoteShell(dest) & " checkout -q " & quoteShell(rev)) != 0:
    discard run("git -C " & quoteShell(dest) & " fetch --quiet origin " & quoteShell(rev))
    if run("git -C " & quoteShell(dest) & " checkout -q " & quoteShell(rev)) != 0:
      return false
  # Submodules (bearssl, boringssl, secp256k1, lsquic, zlib, ...)
  discard run(
    "git -C " & quoteShell(dest) & " submodule update --init --recursive --quiet"
  )
  true

proc packageVersion(pkgDir: string, fallback: string): string =
  result = fallback
  for f in walkFiles(pkgDir / "*.nimble"):
    for line in readFile(f).splitLines:
      let t = line.strip
      if t.startsWith("version"):
        let parts = t.split('=')
        if parts.len >= 2:
          return parts[1].strip().strip(chars = {'"', '\''})
    break

proc writeMeta(pkgDir, url, rev, sha1, ver: string) =
  let meta = %*{
    "url": url,
    "vcsRevision": rev,
    "downloadMethod": "git",
    "versions": [ver],
    "checksums": {"sha1": sha1}
  }
  writeFile(pkgDir / "nimblemeta.json", meta.pretty)

proc installPkg(root, name: string, entry: JsonNode, force: bool): string =
  ## Returns final package directory path.
  let version = entry["version"].getStr
  let rev = entry["vcsRevision"].getStr
  let url = entry["url"].getStr
  let sha1 = entry["checksums"]["sha1"].getStr
  let pkgsDir = root / PkgsRel
  createDir(pkgsDir)

  # Prefer existing dir matching name-*-sha1
  var existing = ""
  for kind, path in walkDir(pkgsDir):
    if kind != pcDir:
      continue
    let base = path.extractFilename
    if base.startsWith(name & "-") and base.endsWith("-" & sha1):
      existing = path
      break

  if existing.len > 0 and not force and fileExists(existing / "nimblemeta.json"):
    # Ensure submodules present (best-effort)
    if dirExists(existing / ".git"):
      discard run(
        "git -C " & quoteShell(existing) &
          " submodule update --init --recursive --quiet"
      )
    echo "  skip ", existing.extractFilename
    return existing

  echo "  install ", name, " @ ", version, " (", rev[0 .. min(11, rev.high)], ")"
  let tmpName = name & "-tmp-" & sha1
  let tmpDest = pkgsDir / tmpName
  if not gitClone(url, tmpDest, rev):
    echo "  FAILED ", name
    quit(1)

  var pkgVer = packageVersion(tmpDest, version.replace("#", ""))
  if pkgVer.len == 0:
    pkgVer = version.replace("#", "")
  let finalName = name & "-" & pkgVer & "-" & sha1
  let finalDest = pkgsDir / finalName
  if finalDest != tmpDest:
    if dirExists(finalDest):
      removeDir(finalDest)
    moveDir(tmpDest, finalDest)
  writeMeta(finalDest, url, rev, sha1, pkgVer)
  echo "  -> ", finalName
  finalDest

proc writePaths(root: string, dirs: seq[string]) =
  var lines = @["--noNimblePath"]
  var sorted = dirs
  sorted.sort()
  for d in sorted:
    lines.add("--path:\"" & d & "\"")
    if dirExists(d / "src"):
      lines.add("--path:\"" & d / "src" & "\"")
  writeFile(root / PathsRel, lines.join("\n") & "\n")
  echo "Wrote ", root / PathsRel, " (", sorted.len, " packages)"

proc applyLibp2pShims(root: string) =
  ## libp2p_mix still imports removed libp2p modules; restore as thin shims.
  var lp = ""
  let pkgs = root / PkgsRel
  for kind, path in walkDir(pkgs):
    if kind != pcDir:
      continue
    let base = path.extractFilename
    if base.startsWith("libp2p-2.2") and dirExists(path / "libp2p"):
      lp = path
      break
  if lp.len == 0:
    echo "  (no libp2p 2.2 package; skip shims)"
    return
  writeFile(
    lp / "libp2p" / "utility.nim",
    """
# Shim: libp2p/utility removed in nim-libp2p 2.x; needed by current libp2p_mix pin.
import ./utils/[opt, shortlog, collections]
export opt, shortlog, collections
""",
  )
  createDir(lp / "libp2p" / "utils")
  writeFile(
    lp / "libp2p" / "utils" / "sequninit.nim",
    """
# Shim: libp2p/utils/sequninit removed; newSeqUninit lives in system.
export system
""",
  )
  echo "  applied libp2p 2.2 shims in ", lp.extractFilename

proc main() =
  let root = getCurrentDir()
  let lockPath = root / LockRel
  if not fileExists(lockPath):
    echo "error: ", lockPath, " not found (run from repo root)"
    quit(1)

  let force = getEnv("INSTALL_FROM_LOCK_FORCE") == "1"
  let lock = parseFile(lockPath)
  echo "Installing packages from ", LockRel, " ..."
  var dirs: seq[string]
  for name, entry in lock["packages"].pairs:
    dirs.add(installPkg(root, name, entry, force))
  writePaths(root, dirs)
  applyLibp2pShims(root)
  echo "Done."

main()
