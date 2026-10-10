{.push raises: [].}

## 404 hints for REST roots whose endpoints are not mounted (yet): the keys are
## the first path segment, the values the message returned to the client.
## NOTE: {.threadvar.} is used to make the global variable GC safe for the
## closures that use it. It is always called from the main thread anyway.
## Ref: https://nim-lang.org/docs/manual.html#threads-gc-safety

import std/tables

var notInstalledTab {.threadvar.}: TableRef[string, string]

const
  RestRootAdmin* = "admin"
  RestRootDebug* = "debug"
  RestRootRelay* = "relay"
  RestRootFilter* = "filter"
  RestRootLightpush* = "lightpush"
  RestRootStore* = "store"
  RestRootMessaging* = "messaging"

proc ensureTab() =
  if notInstalledTab.isNil:
    notInstalledTab = newTable[string, string]()

proc hintFor*(rootPath: string): string =
  ## "" when `rootPath` has no hint.
  if notInstalledTab.isNil:
    return ""
  return notInstalledTab.getOrDefault(rootPath, "")

proc markRestApiInstalled*(rootPath: string) =
  ## Removes the 404 hint for `rootPath`. The hint table is per thread and
  ## shared by every REST server on that thread.
  if not notInstalledTab.isNil():
    notInstalledTab.del(rootPath)

proc markRestApiNotInstalled*(rootPath: string, reason: string) =
  ## Sets the 404 hint for a root whose endpoints are not mounted.
  ensureTab()
  notInstalledTab[rootPath] = reason
