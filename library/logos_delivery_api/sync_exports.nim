## Synchronous entry points: no context, no callback, the value crosses the
## C ABI directly. `{.ffi.}` routes a no-argument proc with a plain return type
## here on its own.

proc logosdelivery_version(): string {.ffi.} =
  ## Same string `waku_version` answers over the context surface.
  WakuNodeVersionString
