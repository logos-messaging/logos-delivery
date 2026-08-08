## Compile-time metadata types for FFI binding generation, populated by the
## {.ffiCtor.}/{.ffi.} macros and consumed by codegen.

import std/[strutils, options]

type
  ABIFormat* {.pure.} = enum
    ## FFI payload wire format. `Cbor` is wired end-to-end; `C` has a type codec
    ## but no proc-dispatch path yet.
    Cbor = "cbor"
    C = "c"

  FFIParamMeta* = object
    name*: string
    typeName*: string
    isPtr*: bool
    isHandle*: bool # {.ffiHandle.} type, wire form uint64

  FFIKind* {.pure.} = enum
    FFI
    CTOR
    DTOR
    STATIC ## `{.ffiStatic.}`: context-independent, its wrapper takes no `ctx`

  FFIProcMeta* = object
    procName*: string
    libName*: string
    kind*: FFIKind
    libTypeName*: string
    doc*: string
    extraParams*: seq[FFIParamMeta] # all params except the lib param
    returnTypeName*: string
    returnIsPtr*: bool
    returnIsHandle*: bool
    abiFormat*: ABIFormat
    scalarFastPath*: bool
      ## `abi = c` proc with an all-scalar signature: uses the CBOR-free fast
      ## path, and binds only in the `abi = c` C header (see `bindableProcs`).

  FFIFieldMeta* = object
    name*: string
    typeName*: string

  FFIEnumValueMeta* = object
    ## One `{.ffi.}` enum value. `wire` is what `$value` yields — the symbol name,
    ## or the associated string if the enum declares one — which is exactly what
    ## cbor_serialization puts on the wire.
    name*: string
    wire*: string
    ord*: int

  FFITypeMeta* = object
    name*: string
    fields*: seq[FFIFieldMeta]
    abiFormat*: ABIFormat
    enumValues*: seq[FFIEnumValueMeta] ## non-empty iff the type is an enum

  FFIConstMeta* = object
    ## A `{.ffiConst.}` value. `value` is the compile-time-evaluated result of
    ## `$theConst`, re-rendered as a literal by each backend.
    name*: string
    typeName*: string
    value*: string

  FFIEventMeta* = object
    ## Library-initiated event from `{.ffiEvent: "wire_name".}`; `wireName` is
    ## the verbatim CBOR `eventType` the foreign side dispatches on.
    wireName*: string
    nimProcName*: string
    libName*: string
    payloadTypeName*: string
    abiFormat*: ABIFormat
    doc*: string

var ffiProcRegistry* {.compileTime.}: seq[FFIProcMeta]
var ffiTypeRegistry* {.compileTime.}: seq[FFITypeMeta]
var ffiEventRegistry* {.compileTime.}: seq[FFIEventMeta]
var ffiConstRegistry* {.compileTime.}: seq[FFIConstMeta]
var currentLibName* {.compileTime.}: string

# Set by `declareLibrary`; the FFI annotations require it.
var libraryDeclared* {.compileTime.}: bool = false

# Set by `genBindings()`. Annotations expanded after it register too late to be emitted, so the macros check this and fail loudly instead of dropping silently.
var genBindingsEmitted* {.compileTime.}: bool = false

# Library-wide default ABI, inherited by each annotation unless it overrides.
var currentDefaultABIFormat* {.compileTime.}: ABIFormat = ABIFormat.Cbor

proc abiCodegenImplemented*(fmt: ABIFormat): bool =
  ## Whether `fmt` has a working proc-dispatch path (both Cbor and C do).
  fmt in {ABIFormat.Cbor, ABIFormat.C}

proc overrideKey*(override: string): string =
  ## Lowercased key of a `key = value` pragma override, e.g. `"abi = c"` → `"abi"`.
  override.split('=')[0].strip().toLowerAscii()

proc parseABIFormatName*(name: string): tuple[ok: bool, fmt: ABIFormat] =
  ## Bare format name ("c"/"cbor", case-insensitive) → ABIFormat; else ok=false.
  case name.strip().toLowerAscii()
  of "cbor":
    (true, ABIFormat.Cbor)
  of "c":
    (true, ABIFormat.C)
  else:
    (false, ABIFormat.Cbor)

proc parseAbiSpec*(override: string): tuple[ok: bool, fmt: ABIFormat, err: string] =
  ## Parse an `"abi = <format>"` override; on bad grammar returns ok=false + err.
  let parts = override.split('=')
  if parts.len != 2:
    return (
      false,
      ABIFormat.Cbor,
      "invalid ABI override: '" & override & "'; expected `abi = c` or `abi = cbor`",
    )
  if parts[0].strip().toLowerAscii() != "abi":
    return (
      false,
      ABIFormat.Cbor,
      "invalid ABI override: '" & override & "'; expected `abi = c` or `abi = cbor`",
    )
  let (ok, fmt) = parseABIFormatName(parts[1])
  if not ok:
    return (
      false,
      ABIFormat.Cbor,
      "unknown ABI format: '" & parts[1].strip() & "'; valid values are `c` and `cbor`",
    )
  (true, fmt, "")

# Lib type name (set by declareLibrary) so handle-receiver procs resolve the pool.
var currentLibType* {.compileTime.}: string

# Names of types marked `{.ffiHandle.}` (wire form uint64).
var ffiHandleTypeNames* {.compileTime.}: seq[string]

proc isFFIHandleTypeName*(name: string): bool {.compileTime.} =
  name in ffiHandleTypeNames

func isEnum*(t: FFITypeMeta): bool =
  return t.enumValues.len > 0

# Names of `{.ffi.}` enum types; the `abi = c` wire path has to reject them.
var ffiEnumTypeNames* {.compileTime.}: seq[string]

proc isFFIEnumTypeName*(name: string): bool {.compileTime.} =
  name in ffiEnumTypeNames

func isStatic*(p: FFIProcMeta): bool =
  p.kind == FFIKind.STATIC

type ClassifiedProcs* = object
  ctors*: seq[FFIProcMeta]
  methods*: seq[FFIProcMeta]
  statics*: seq[FFIProcMeta]
  dtor*: Option[FFIProcMeta]

func classifyProcs*(procs: seq[FFIProcMeta]): ClassifiedProcs =
  ## Splits the registry into constructors, methods, statics and the first destructor.
  var c: ClassifiedProcs
  for p in procs:
    case p.kind
    of FFIKind.CTOR:
      c.ctors.add(p)
    of FFIKind.FFI:
      c.methods.add(p)
    of FFIKind.STATIC:
      c.statics.add(p)
    of FFIKind.DTOR:
      if c.dtor.isNone():
        c.dtor = some(p)
  c

func dtorProcName*(c: ClassifiedProcs): string =
  ## The destructor's proc name, or "" when the library has no destructor.
  if c.dtor.isSome():
    c.dtor.get().procName
  else:
    ""

func replyProcs*(c: ClassifiedProcs): seq[FFIProcMeta] =
  ## Procs that reply with a decoded value: methods and statics.
  c.methods & c.statics

proc ridesAsPtr*(ep: FFIParamMeta): bool =
  ## True if the param crosses the wire as an opaque uint64 (raw ptr or handle).
  ep.isPtr or ep.isHandle

proc returnRidesAsPtr*(p: FFIProcMeta): bool =
  ## True if the return crosses the wire as an opaque uint64 (raw ptr or handle).
  p.returnIsPtr or p.returnIsHandle

# Target language(s), override with -d:targetLang=cpp; comma-separated list allowed.
const targetLang* {.strdefine.} = "rust"

# Output dir override (-d:ffiOutputDir); empty derives `<lang>_bindings/` by src.
const ffiOutputDir* {.strdefine.} = ""

# Nim src path override relative to outputDir (-d:ffiSrcPath); empty derives it.
const ffiSrcPath* {.strdefine.} = ""

# When true, targets without scalar codegen silently omit scalar-only `abi = c` procs rather than failing the build. Off by default so the drop is loud; see genBindings().
const ffiAllowScalarSkip* {.booldefine.} = false
