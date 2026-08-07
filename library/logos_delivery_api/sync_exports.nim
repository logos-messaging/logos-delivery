## `{.ffiExport.}` entry points: no context, no callback, the value crosses the
## C ABI directly.

proc logosdelivery_version(): string {.ffiExport.} =
  ## Same string `waku_version` answers over the context surface.
  WakuNodeVersionString
