## Picks the FFI path of a proc from the shape of its signature.
##
## `{.ffi.}`, `{.ffiStatic.}`, `{.ffiExport.}`, `{.ffiDtor.}` and `{.ffiEvent.}`
## own five disjoint shapes, so one router serves all five. Each shape that the
## router claims fails to compile under any other pragma today, so the router
## only turns a compile error into the meaning the writer intended.
##
## `{.ffiCtor.}` stays explicit, because its shape is not free. A ctor differs
## from a static call by one token: the type inside `Result`. A static call that
## returns the library type builds today and exports a working C symbol. A
## router would silently give it the ctor ABI instead.

import std/macros
import ../codegen/meta
import ./ffi_codegen_common

type FFIPath* = enum
  fpMethod ## A library or handle receiver, and an async result.
  fpStatic ## No receiver, and an async result.
  fpExport ## No arguments, and a synchronous result.
  fpDtor ## A library receiver, and no result.
  fpEvent ## A payload parameter, and no result.

func pathPragma*(path: FFIPath): string =
  case path
  of fpMethod: "`.ffi.`"
  of fpStatic: "`.ffiStatic.`"
  of fpExport: "`.ffiExport.`"
  of fpDtor: "`.ffiDtor.`"
  of fpEvent: "`.ffiEvent.`"

func pathShape*(path: FFIPath): string =
  case path
  of fpMethod:
    "the first parameter is the library type or an {.ffiHandle.} type, and the " &
      "return type is Future[Result[T, string]]"
  of fpStatic:
    "there is no library receiver, and the return type is Future[Result[T, string]]"
  of fpExport:
    "there are no parameters, and the return type is a plain Nim type"
  of fpDtor:
    "there is one library parameter, and the return type is nothing or Future[void]"
  of fpEvent:
    "there is a payload parameter that is not the library type, and there is no result"

func isFuture(t: NimNode): bool =
  return
    t.kind == nnkBracketExpr and t.len == 2 and t[0].kind == nnkIdent and
    $t[0] == "Future"

func isFutureVoid(t: NimNode): bool =
  return isFuture(t) and t[1].kind == nnkIdent and $t[1] == "void"

proc isLibReceiver(t: NimNode): bool {.compileTime.} =
  ## The receiver is the type that `declareLibrary` recorded, or a handle type.
  if t.kind != nnkIdent:
    return false
  return ($t == currentLibType and currentLibType.len > 0) or isFFIHandleTypeName($t)

proc routeFFIProc*(prc: NimNode): FFIPath {.compileTime.} =
  ## Reads the receiver and the return type, then names the path.
  let params = prc.params
  let ret = params[0]
  let hasReceiver = params.len > 1 and isLibReceiver(params[1][1])

  if hasReceiver:
    return if ret.kind == nnkEmpty or isFutureVoid(ret): fpDtor else: fpMethod
  if params.len == 1 and not isFuture(ret):
    return fpExport
  # A static call always returns Future[Result[T, string]], so a payload
  # parameter with no result can only be an event.
  if params.len > 1 and ret.kind == nnkEmpty:
    return fpEvent
  return fpStatic

proc assertFFIPath*(prc: NimNode, want: FFIPath) {.compileTime.} =
  ## Guards an explicit pragma against a signature that routes elsewhere.
  let got = routeFFIProc(prc)
  if got == want:
    return
  let name = $procIdent(prc)
  # A receiver is the one mismatch a caller can read straight off the signature.
  if want == fpStatic and got == fpMethod:
    error(
      "`.ffiStatic.` proc " & name & " takes " & prc.params[1][1].repr &
        " as its first parameter, which is the library type or an {.ffiHandle.} type. " &
        "A receiver belongs to a context. Make it an `{.ffi.}` method instead."
    )
  error(
    pathPragma(want) & " proc " & name & " has the shape of a " & pathPragma(got) &
      " proc. Use " & pathPragma(got) & " here, or make sure that " & pathShape(want) &
      "."
  )
