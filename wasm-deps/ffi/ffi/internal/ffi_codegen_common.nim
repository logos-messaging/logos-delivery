## Compile-time pieces that more than one `{.ffi.}` codegen path shares.

import std/macros

func unwrapPostfix*(n: NimNode): NimNode =
  ## Strips the `*` of an exported name, so a name node reads the same whether
  ## the writer exported it or not.
  return
    if n.kind == nnkPostfix:
      n[1]
    else:
      n

func procIdent*(prc: NimNode): NimNode =
  return unwrapPostfix(prc[0])

proc buildLibReadyGuard*(
    ctxHandlerName, libTypeName: NimNode
): NimNode {.compileTime.} =
  ## Rejects a request that reaches the FFI thread before the ctor stores a
  ## library. The guard applies only to a `ref` type. For an `object` type the
  ## fallback is a usable zero value, but for a `ref` type it is nil. The guard
  ## runs in the handler, behind the ctor in the queue. Thus a host can send a
  ## call before it waits for the create callback.
  quote:
    when `libTypeName` is ref:
      if not `ctxHandlerName`[].libReady.load():
        return
          err("library is not initialized: the constructor failed or has not run yet")
