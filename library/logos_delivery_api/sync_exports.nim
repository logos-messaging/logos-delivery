## `{.ffiExport.}` entry points: no context, no callback, the return value
## crosses the C ABI directly. The `{.ffi.}` surface next door needs both.

proc logosdelivery_version(): string {.ffiExport.} =
  ## Same string `waku_version` answers over the context surface.
  WakuNodeVersionString
