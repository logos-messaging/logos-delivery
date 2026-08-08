## Structured type model shared by the C / C++ / Rust binding generators:
## `parseFFIType` parses a Nim type string, `renderNative` walks it per backend.

import std/[strutils, options]

type
  ScalarKind* {.pure.} = enum
    skBool
    skI8
    skI16
    skI32
    skI64
    skU8
    skU16
    skU32
    skU64
    skF32
    skF64

  FFITypeKind* {.pure.} = enum
    ftScalar
    ftStr
    ftBytes
    ftSeq
    ftOpt
    ftPtr
    ftStruct

  FFIType* = ref object
    case kind*: FFITypeKind
    of ftScalar:
      scalar*: ScalarKind
    of ftSeq, ftOpt:
      elem*: FFIType
    of ftStruct:
      name*: string
    else:
      discard

  NativeTypeMap* = object
    ## Per-backend type names; `structName` nil ⇒ user type name passes through.
    scalar*: proc(s: ScalarKind): string {.noSideEffect, nimcall.}
    str*: string
    bytes*: string
    ptrType*: string
    seqOf*: proc(elem: string): string {.noSideEffect, nimcall.}
    optOf*: proc(elem: string): string {.noSideEffect, nimcall.}
    structName*: proc(name: string): string {.noSideEffect, nimcall.}

func genericInnerType*(typeName, prefix: string): string =
  ## Inner type of `Prefix[Inner]`, e.g. ("seq[int]", "seq[") → "int"; "" if no match.
  if typeName.startsWith(prefix) and typeName.endsWith("]"):
    return typeName[prefix.len .. ^2]
  return ""

func scalarKind(t: string): Option[ScalarKind] =
  case t
  of "bool":
    some(skBool)
  of "int8":
    some(skI8)
  of "int16":
    some(skI16)
  of "int32":
    some(skI32)
  of "int", "int64":
    some(skI64)
  of "uint8", "byte":
    some(skU8)
  of "uint16":
    some(skU16)
  of "uint32":
    some(skU32)
  of "uint", "uint64":
    some(skU64)
  of "float32":
    some(skF32)
  of "float", "float64":
    some(skF64)
  else:
    none(ScalarKind)

func parseFFIType*(typeName: string): FFIType =
  ## Nim type string → shared `FFIType`: ptr/pointer, seq[byte]→bytes, seq/Option/Maybe,
  ## scalars, string, else struct.
  let t = typeName.strip()
  if t.startsWith("ptr ") or t == "pointer":
    return FFIType(kind: ftPtr)

  let seqInner = genericInnerType(t, "seq[")
  if seqInner.len > 0:
    let inner = seqInner.strip()
    if inner == "byte" or inner == "uint8":
      return FFIType(kind: ftBytes)
    return FFIType(kind: ftSeq, elem: parseFFIType(inner))

  var optInner = genericInnerType(t, "Option[")
  if optInner.len == 0:
    optInner = genericInnerType(t, "Maybe[")
  if optInner.len > 0:
    return FFIType(kind: ftOpt, elem: parseFFIType(optInner.strip()))

  let sc = scalarKind(t)
  if sc.isSome():
    return FFIType(kind: ftScalar, scalar: sc.get())
  if t == "string" or t == "cstring":
    return FFIType(kind: ftStr)
  FFIType(kind: ftStruct, name: t)

func renderNative*(m: NativeTypeMap, t: FFIType): string =
  ## Recursively walks `t` into a native type string for backend `m`.
  case t.kind
  of ftScalar:
    m.scalar(t.scalar)
  of ftStr:
    m.str
  of ftBytes:
    m.bytes
  of ftPtr:
    m.ptrType
  of ftSeq:
    m.seqOf(renderNative(m, t.elem))
  of ftOpt:
    m.optOf(renderNative(m, t.elem))
  of ftStruct:
    if m.structName.isNil():
      t.name
    else:
      m.structName(t.name)
