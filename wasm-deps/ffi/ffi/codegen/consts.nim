## Literal rendering for `{.ffiConst.}` values, shared by the C/C++/Rust generators.
## The registry stores Nim's `$value`; each backend re-quotes it for its syntax.

import std/strutils
import ./types_ir

func cByteEscape(ch: char): string =
  ## 3-digit octal: C caps an octal escape at 3 digits, so a following digit
  ## can't be swallowed into it the way it can with `\x`.
  return "\\" & toOct(ord(ch), 3)

func rustByteEscape(ch: char): string =
  return "\\x" & toHex(ord(ch), 2)

func escapeLit(
    s: string, byteEscape: proc(ch: char): string {.noSideEffect, nimcall.}
): string =
  var escaped = ""
  for ch in s:
    case ch
    of '"':
      escaped.add("\\\"")
    of '\\':
      escaped.add("\\\\")
    of '\n':
      escaped.add("\\n")
    of '\r':
      escaped.add("\\r")
    of '\t':
      escaped.add("\\t")
    else:
      if ch < ' ' or ch == '\x7F':
        escaped.add(byteEscape(ch))
      else:
        escaped.add(ch)
  return escaped

func cEscapeStringLit*(s: string): string =
  return escapeLit(s, cByteEscape)

func rustEscapeStringLit*(s: string): string =
  return escapeLit(s, rustByteEscape)

func cConstValue*(t: FFIType, value: string): string =
  ## C/C++ literal. Every emission site is a typed declaration, so the declared
  ## type already fixes the width; only the two cases the type can't rescue get
  ## a suffix — `ULL` because a decimal above `INT64_MAX` fits no signed type,
  ## and `f` because a bare `1.5` is a double and narrowing it warns.
  case t.kind
  of ftStr:
    return "\"" & cEscapeStringLit(value) & "\""
  of ftScalar:
    case t.scalar
    of skU64:
      return value & "ULL"
    of skF32:
      return value & "f"
    else:
      return value
  else:
    return value

func rustConstValue*(t: FFIType, value: string): string =
  ## Rust literal; the declared type annotation carries the width, so no suffix.
  case t.kind
  of ftStr:
    return "\"" & rustEscapeStringLit(value) & "\""
  else:
    return value
