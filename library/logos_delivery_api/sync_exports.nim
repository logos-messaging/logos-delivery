## Synchronous entry points: no context, no callback, the value crosses the
## C ABI directly. `{.ffi.}` routes a no-argument proc with a plain return type
## here on its own.

when defined(ffiPollMode):
  # The poll model has no synchronous path: every export answers with a
  # message, this one on the library's static context.
  proc logosdelivery_version(): Future[Result[string, string]] {.ffi.} =
    return ok(WakuNodeVersionString)
else:
  proc logosdelivery_version(): string {.ffi.} =
    ## Same string `waku_version` answers over the context surface.
    WakuNodeVersionString
