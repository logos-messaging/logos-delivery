## Simple synchronous C export for a nim-ffi library.
##
## `{.ffi.}` and `{.ffiCtor.}` give the async path. That path uses a context
## handle and encodes the data with CBOR. It fits a library that keeps state
## across many calls. `{.ffiExport.}` covers the other common case: a few simple
## lifecycle entry points. The host loads them with `dlopen` and `dlsym`, then
## calls them synchronously. There is no context, no callback and no CBOR. The
## return value of the function crosses the ABI directly.
##
## Write native Nim types. `ffiExport` maps them to the C ABI:
##   int / int64      -> C  long long
##   int32 / bool     -> C  int
##   uint / uint64    -> C  unsigned long long
##   float            -> C  double
##   string           -> C  const char*  (valid until the same thread calls again)
##   (no return)      -> C  void
## A return type with no mapping is a compile error.
## The `const char*` buffer belongs to the calling thread. Copy the bytes before
## that thread calls another `{.ffiExport.}` proc that returns a string.
## `ffiExport` also injects the `initializeLibrary()` call of the library. The Nim
## runtime therefore starts on the first call, and the host never calls NimMain.
## The wrapper catches every exception of the body, prints it and returns the
## zero value, because an exception must not cross the C ABI.
##
##   declareLibraryBase("myLib")                       # emits initializeLibrary()
##   proc my_start(): int {.ffiExport.} = 0            # -> long long my_start(void)
##   proc my_alive(): uint64 {.ffiExport.} = beats     # -> unsigned long long my_alive(void)
##   proc my_error(): string {.ffiExport.} = lastErr   # -> const char* my_error(void)
##
## Build the shared library with `--noMain --nimMainPrefix:libmyLib`. A proc with
## `{.ffiExport.}` takes no arguments. For a call with arguments, use `{.ffi.}`.

import std/macros
import ./ffi_route
import ./ffi_codegen_common

const passthroughCTypes = [
  "cint", "cuint", "clong", "culong", "clonglong", "culonglong", "cfloat", "cdouble",
  "cstring", "pointer",
]

proc cReturnType(t: NimNode, exportName: string): NimNode =
  ## Maps the native Nim return type to the C ABI type that crosses the boundary.
  ## A type with no mapping is an error: emitting the Nim type as-is would export
  ## a symbol whose ABI no host can call.
  if t.kind == nnkEmpty:
    return t
  if t.kind == nnkIdent:
    case $t
    of "int", "int64":
      # `int` is pointer-wide, so `cint` would truncate it on a 64-bit host.
      return ident("clonglong")
    of "int8", "int16", "int32", "bool":
      return ident("cint")
    of "uint", "uint64":
      return ident("culonglong")
    of "uint8", "uint16", "uint32":
      return ident("cuint")
    of "float", "float64":
      return ident("cdouble")
    of "float32":
      return ident("cfloat")
    of "string":
      return ident("cstring")
    else:
      if $t in passthroughCTypes:
        return t
  error(
    "`.ffiExport.` proc " & exportName & " returns " & t.repr &
      ", which has no C ABI mapping. Return a scalar, a bool, a string, a C type, " &
      "or nothing. For a richer return type, use `{.ffi.}`."
  )

proc withoutFFIPragmas(pragmas: NimNode): NimNode =
  ## Drops only the pragma that routed the proc here, so a `raises` or `gcsafe`
  ## the writer asked for still applies to the body.
  if pragmas.kind != nnkPragma:
    return newEmptyNode()
  var kept = nnkPragma.newTree()
  for p in pragmas:
    let name =
      if p.kind in {nnkExprColonExpr, nnkCall}:
        p[0]
      else:
        p
    if name.kind == nnkIdent and $name in ["ffi", "ffiExport"]:
      continue
    kept.add(p)
  return
    if kept.len == 0:
      newEmptyNode()
    else:
      kept

proc buildFFIExportProc*(prc: NimNode): NimNode {.compileTime.} =
  ## Emits the synchronous C export. `{.ffi.}` and `{.ffiExport.}` share it.
  prc.expectKind({nnkProcDef, nnkFuncDef})
  let exportName = $procIdent(prc)
  let params = prc.params
  let nativeRet = params[0]
  let cRet = cReturnType(nativeRet, exportName)

  # The user body becomes a private impl proc that the exported wrapper calls.
  let implName = genSym(nskProc, exportName & "Impl")
  var impl = copyNimTree(prc)
  impl[0] = implName
  impl[4] = withoutFFIPragmas(prc[4])

  let wrapName = ident(exportName)
  let boot = quote:
    when declared(initializeLibrary):
      initializeLibrary()

  # A Nim exception that unwinds through a cdecl frame into the host is
  # undefined behaviour, so every wrapper catches and reports instead.
  let raiseNote = newLit("error: " & exportName & " raised: ")

  var res = newStmtList(impl)

  if nativeRet.kind == nnkIdent and $nativeRet == "string":
    # One buffer per calling thread: a process-wide buffer would let one thread
    # free the bytes another thread is still reading.
    let buf = genSym(nskVar, exportName & "Buf")
    res.add quote do:
      var `buf` {.threadvar.}: pointer
      proc `wrapName`(): cstring {.exportc: `exportName`, cdecl, dynlib, raises: [].} =
        `boot`
        var s = ""
        try:
          s = `implName`()
        except CatchableError as e:
          echo `raiseNote`, e.msg
        if not `buf`.isNil():
          deallocShared(`buf`)
        `buf` = allocShared(s.len + 1)
        if s.len > 0:
          copyMem(`buf`, unsafeAddr s[0], s.len)
        cast[ptr UncheckedArray[char]](`buf`)[s.len] = '\0'
        return cast[cstring](`buf`)

  elif nativeRet.kind == nnkEmpty:
    res.add quote do:
      proc `wrapName`() {.exportc: `exportName`, cdecl, dynlib, raises: [].} =
        `boot`
        try:
          `implName`()
        except CatchableError as e:
          echo `raiseNote`, e.msg

  else:
    res.add quote do:
      proc `wrapName`(): `cRet` {.exportc: `exportName`, cdecl, dynlib, raises: [].} =
        `boot`
        try:
          return `cRet`(`implName`())
        except CatchableError as e:
          echo `raiseNote`, e.msg
          return `cRet`(0)

  return res

macro ffiExport*(prc: untyped): untyped =
  ## Marks a proc that takes no arguments as a simple synchronous C export. The
  ## macro maps the native Nim return type to the C ABI and starts the Nim
  ## runtime. `{.ffi.}` reaches the same path from the shape alone. See the
  ## module doc.
  prc.expectKind({nnkProcDef, nnkFuncDef})
  assertFFIPath(prc, fpExport)
  return buildFFIExportProc(prc)
