## Generated Python wrapper for the CBOR FFI surface.
##
## The generated `<lib>.py` ships alongside the shared library and uses
## ctypes for the C ABI plus the `cbor2` package for encode/decode.
## Discovery endpoints (`list_apis`, `get_schema`) return JSON and are
## decoded via stdlib `json`. Foreign Python projects only need to
## install `cbor2` (pure-Python, widely packaged) — no other runtime
## dependencies.
##
## The wrapper emits typed `dataclass` definitions for each registered
## request response, request args, and event payload type, and per-
## request methods on the libname-PascalCase wrapper class that
## CBOR-encode the args, dispatch through the C gate, and decode the
## response envelope into a `Result` object. Per-event `on_<name>(callback)`
## methods register a typed callable that receives the owning library
## instance plus the unpacked event payload fields; `off_<name>(handle = 0)`
## removes a single registration (or, with handle 0, all of them).
## Trampolines are kept alive in a per-event handler map mirroring the
## C++ EventDispatcher's GC anchor.
##
## Type-matrix coverage (Phase 7D):
##   - Primitives: bool, int/intN, uint/uintN/byte, float/floatN, string,
##     char.
##   - Enums (atkEnum) → Python IntEnum classes.
##   - Distinct/Alias (atkDistinct/atkAlias) → Python type alias of the
##     resolved underlying type (typing.NewType-style: simple `=` alias).
##   - Registered objects → @dataclass with typed fields and a paired
##     `_decode_<T>` / `_encode_<T>` helper.
##   - Composite types: seq[T], array[N, T] (typed as List[<inner>]),
##     including seq[byte] and seq[<object>]; nested objects.
## Unmappable types still produce a TODO stub so the wrapper compiles.

{.push raises: [].}

import std/[macros, strutils, tables]
import ./api_common, ./api_schema
import ./helper/broker_utils # reduced-A: per-interface partitioning

# ---------------------------------------------------------------------------
# Nim → Python type mapping (registry-aware)
# ---------------------------------------------------------------------------

const pyPrimMap = {
  "bool": "bool",
  "string": "str",
  "char": "str",
  "int": "int",
  "int8": "int",
  "int16": "int",
  "int32": "int",
  "int64": "int",
  "uint": "int",
  "uint8": "int",
  "uint16": "int",
  "uint32": "int",
  "uint64": "int",
  "byte": "int",
  "float": "float",
  "float32": "float",
  "float64": "float",
}.toTable

proc isPrimitive(nimType: string): bool {.compileTime.} =
  nimType.strip() in pyPrimMap

proc primPyHint(nimType: string): string {.compileTime.} =
  pyPrimMap.getOrDefault(nimType.strip(), "")

proc unwrapBracket(s, head: string): string {.compileTime.} =
  ## "seq[X]" + "seq" -> "X"
  let t = s.strip()
  t[head.len + 1 .. ^2].strip()

proc parseArrayInner(s: string): string {.compileTime.} =
  ## "array[N, T]" -> "T"
  let inner = s.strip()[6 ..^ 2]
  let comma = inner.find(',')
  if comma < 0:
    return ""
  inner[comma + 1 .. ^1].strip()

proc parseTableParams*(s: string): (string, string) {.compileTime.} =
  ## "Table[K, V]" -> ("K", "V"). Splits on the first top-level comma so a
  ## composite value type's own commas (array/nested Table) are preserved.
  let inner = s.strip()[6 ..^ 2]
  var depth = 0
  for i in 0 ..< inner.len:
    case inner[i]
    of '[', '(':
      inc depth
    of ']', ')':
      dec depth
    of ',':
      if depth == 0:
        return (inner[0 ..< i].strip(), inner[i + 1 .. ^1].strip())
    else:
      discard
  ("", "")

proc nimTypeToPyHint*(nimType: string): string {.compileTime.} =
  ## Recursive Nim → Python type hint. Falls back to "" for types we
  ## don't yet know how to map (the caller emits a TODO).
  let t = nimType.strip()
  let lower = t.toLowerAscii()
  if isPrimitive(t):
    return primPyHint(t)
  if lower == "seq[byte]":
    # CBOR major type 2 (byte string) decodes to Python `bytes`; mirror
    # that on the wrapper side so `Option[seq[byte]]` inside an Option
    # also resolves to `Optional[bytes]` rather than `Optional[List[int]]`.
    return "bytes"
  if lower.startsWith("seq[") and lower.endsWith("]"):
    let inner = nimTypeToPyHint(unwrapBracket(t, "seq"))
    return
      if inner.len > 0:
        "List[" & inner & "]"
      else:
        "List[Any]"
  if lower.startsWith("array["):
    let elem = parseArrayInner(t)
    let inner = nimTypeToPyHint(elem)
    return
      if inner.len > 0:
        "List[" & inner & "]"
      else:
        "List[Any]"
  if lower.startsWith("option[") and lower.endsWith("]"):
    let inner = nimTypeToPyHint(unwrapBracket(t, "option"))
    return
      if inner.len > 0:
        "Optional[" & inner & "]"
      else:
        "Optional[Any]"
  if lower.startsWith("table[") and lower.endsWith("]"):
    let (k, v) = parseTableParams(t)
    let kh = nimTypeToPyHint(k)
    let vh = nimTypeToPyHint(v)
    return
      if kh.len > 0 and vh.len > 0:
        "Dict[" & kh & ", " & vh & "]"
      else:
        "Dict[Any, Any]"
  if isTypeRegistered(t):
    let entry = lookupTypeEntry(t)
    case entry.kind
    of atkObject:
      return t
    of atkEnum:
      return t
    of atkAlias, atkDistinct:
      # Reference the emitted alias BY NAME so fields/params keep the meaningful
      # type (`ContentTopic`, `Timestamp`) instead of flattening to the
      # underlying; "" when the underlying doesn't map.
      if nimTypeToPyHint(resolveUnderlyingType(t)).len > 0:
        return t
      return ""
  ""

proc nimTypeToPyDefault*(nimType: string): string {.compileTime.} =
  ## Default value literal for a dataclass field. Collections use
  ## `field(default_factory=list)`; objects/enums use `None` (callers
  ## construct lazily — dataclass init still needs a callable default).
  let t = nimType.strip()
  let lower = t.toLowerAscii()
  case t
  of "bool":
    return "False"
  of "string", "char":
    return "\"\""
  of "int", "int8", "int16", "int32", "int64", "uint", "uint8", "byte", "uint16",
      "uint32", "uint64":
    return "0"
  of "float32", "float", "float64":
    return "0.0"
  else:
    discard
  if lower == "seq[byte]":
    return "b\"\""
  if lower.startsWith("seq[") or lower.startsWith("array["):
    return "field(default_factory=list)"
  if lower.startsWith("option["):
    return "None"
  if isTypeRegistered(t):
    let entry = lookupTypeEntry(t)
    case entry.kind
    of atkObject:
      return "field(default_factory=" & t & ")"
    of atkEnum:
      return t & "(0)"
    of atkAlias, atkDistinct:
      return nimTypeToPyDefault(resolveUnderlyingType(t))
  "None"

proc isPyMappable*(nimType: string): bool {.compileTime.} =
  nimTypeToPyHint(nimType).len > 0

# ---------------------------------------------------------------------------
# Per-type encoder / decoder expression builders.
#
# These produce the Python source for the `_encode_<T>` / `_decode_<T>`
# helpers (called from request method bodies and from event trampolines).
# Returning a string keeps the codegen flat; the wrapper file is plain
# Python anyway.
# ---------------------------------------------------------------------------

proc pyKeyClass(keyType: string): string {.compileTime.} =
  ## Classify a Table key type for text-key conversion: "str" (string/char),
  ## "int" (int8..64), or "enum:<Name>". Distinct keys resolve to their base.
  let t = keyType.strip()
  if isTypeRegistered(t):
    let entry = lookupTypeEntry(t)
    if entry.kind == atkEnum:
      return "enum:" & t
    if entry.kind in {atkAlias, atkDistinct}:
      return pyKeyClass(resolveUnderlyingType(t))
  let lo = t.toLowerAscii()
  if lo == "string" or lo == "char":
    return "str"
  "int"

proc pyDecodeExpr(nimType, src: string): string {.compileTime.} =
  ## Python expression that decodes the value at `src` (a Python
  ## expression yielding the raw cbor2 result) into the in-memory
  ## representation of `nimType`.
  let t = nimType.strip()
  let lower = t.toLowerAscii()
  if lower.startsWith("table[") and lower.endsWith("]"):
    # Keys arrive as CBOR text strings; rebuild the declared key type.
    let (k, v) = parseTableParams(t)
    let kc = pyKeyClass(k)
    let keyExpr =
      if kc == "str":
        "_k"
      elif kc == "int":
        "int(_k)"
      else:
        kc[5 ..^ 1] & "(int(_k))" # enum:<Name> -> Name(int(_k))
    return
      "{" & keyExpr & ": " & pyDecodeExpr(v, "_v") & " for _k, _v in (" & src &
      " or {}).items()}"
  if t == "bool":
    return "bool(" & src & ") if isinstance(" & src & ", bool) else False"
  if t == "string" or t == "char":
    return "(" & src & " if isinstance(" & src & ", str) else \"\")"
  if t in [
    "int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32",
    "uint64", "byte",
  ]:
    return "(int(" & src & ") if isinstance(" & src & ", int) else 0)"
  if t in ["float", "float32", "float64"]:
    return "(float(" & src & ") if isinstance(" & src & ", (int, float)) else 0.0)"
  if lower == "seq[byte]":
    # CBOR byte string → Python `bytes`. Accept the byte-string shape
    # cbor2 produces directly, and tolerate the legacy list-of-int
    # shape (e.g. when a sender emits major type 4 instead of 2).
    return "(bytes(" & src & ") if " & src & " is not None else b\"\")"
  if lower.startsWith("seq[") and lower.endsWith("]"):
    let inner = unwrapBracket(t, "seq")
    let raw = "(" & src & " or [])"
    return "[" & pyDecodeExpr(inner, "_x") & " for _x in " & raw & "]"
  if lower.startsWith("array["):
    let elem = parseArrayInner(t)
    let raw = "(" & src & " or [])"
    return "[" & pyDecodeExpr(elem, "_x") & " for _x in " & raw & "]"
  if lower.startsWith("option[") and lower.endsWith("]"):
    let inner = unwrapBracket(t, "option")
    return "(None if " & src & " is None else " & pyDecodeExpr(inner, src) & ")"
  if isTypeRegistered(t):
    let entry = lookupTypeEntry(t)
    case entry.kind
    of atkObject:
      return "_decode_" & t & "(" & src & ")"
    of atkEnum:
      return "_decode_" & t & "(" & src & ")"
    of atkAlias, atkDistinct:
      return pyDecodeExpr(resolveUnderlyingType(t), src)
  # Unknown — pass through; cbor2 already gave us something.
  src

proc pyEncodeExpr(nimType, src: string): string {.compileTime.} =
  ## Python expression that encodes the value at `src` into the
  ## CBOR-friendly representation expected by the Nim provider for
  ## `nimType`.
  let t = nimType.strip()
  let lower = t.toLowerAscii()
  if isPrimitive(t):
    return src
  if lower.startsWith("table[") and lower.endsWith("]"):
    # Stringify non-string keys so the wire matches the Nim text-key format.
    let (k, v) = parseTableParams(t)
    let kc = pyKeyClass(k)
    let keyExpr =
      if kc == "str":
        "str(_k)"
      elif kc == "int":
        "str(_k)"
      else:
        "str(int(_k))" # enum -> ordinal text
    return
      "{" & keyExpr & ": " & pyEncodeExpr(v, "_v") & " for _k, _v in (" & src &
      " or {}).items()}"
  if lower == "seq[byte]":
    # cbor2 encodes Python `bytes` as CBOR byte string (major type 2),
    # which is what the Nim provider expects. Tolerate list-of-int input
    # by converting on the fly.
    return
      "(" & src & " if isinstance(" & src & ", (bytes, bytearray)) else bytes(" & src &
      " or []))"
  if lower.startsWith("seq[") and lower.endsWith("]"):
    let inner = unwrapBracket(t, "seq")
    return "[" & pyEncodeExpr(inner, "_x") & " for _x in (" & src & " or [])]"
  if lower.startsWith("array["):
    let elem = parseArrayInner(t)
    return "[" & pyEncodeExpr(elem, "_x") & " for _x in (" & src & " or [])]"
  if lower.startsWith("option[") and lower.endsWith("]"):
    let inner = unwrapBracket(t, "option")
    return "(None if " & src & " is None else " & pyEncodeExpr(inner, src) & ")"
  if isTypeRegistered(t):
    let entry = lookupTypeEntry(t)
    case entry.kind
    of atkObject:
      return "_encode_" & t & "(" & src & ")"
    of atkEnum:
      return "int(" & src & ")"
    of atkAlias, atkDistinct:
      return pyEncodeExpr(resolveUnderlyingType(t), src)
  src

proc snakeToLowerCamel(s: string): string {.compileTime.} =
  result = ""
  var capitalize = false
  for ch in s:
    if ch == '_':
      capitalize = true
    elif capitalize:
      result.add(toUpperAscii(ch))
      capitalize = false
    else:
      result.add(ch)

proc snakeToUpperCamel(s: string): string {.compileTime.} =
  result = snakeToLowerCamel(s)
  if result.len > 0:
    result[0] = toUpperAscii(result[0])

# ---------------------------------------------------------------------------
# File emission
# ---------------------------------------------------------------------------

{.pop.}

proc subClassName(iface: string): string {.compileTime.} =
  ## Wrapper class name for a sub-interface: strip a leading `I` before an
  ## uppercase letter (IWidget -> Widget), else use the name as-is.
  if iface.len > 1 and iface[0] == 'I' and iface[1] in {'A' .. 'Z'}:
    iface[1 ..^ 1]
  else:
    iface

proc generateCborPyFile*(
    outDir: string,
    libName: string,
    requestEntries: seq[CborRequestEntry],
    eventEntries: seq[CborEventEntry],
    mainClass: string = "",
    asyncTimeoutMs: int = 30000,
    asyncQueueDepth: int = 64,
    signalEntries: seq[CborSignalEntry] = @[],
) {.compileTime, raises: [].} =
  ## Writes the Python wrapper module (.py) for a CBOR-mode library.
  ensureGeneratedOutputDir(outDir)

  let pyPath =
    if outDir.len > 0:
      outDir & "/" & libName & ".py"
    else:
      libName & ".py"
  let p = libName & "_"

  # Derive Python class name from libName (PascalCase) the same way the
  # native Python codegen does — gives the same public class name in both
  # builds so a single test source can drive either.
  var className = ""
  block:
    var capitalize = true
    for ch in libName:
      if ch == '_' or ch == '-':
        capitalize = true
      elif capitalize:
        className.add(chr(ord(ch) - 32 * ord(ch in {'a' .. 'z'})))
        capitalize = false
      else:
        className.add(ch)

  # Note: type emission below walks `gApiTypeRegistry` directly so we
  # cover every referenced object/enum/distinct, not just request
  # response or event payload types. The objectNames seq populated
  # later is what request/event method emission filters against.

  var py =
    "# Generated by nim-brokers CBOR FFI codegen — do not edit.\n" & "#\n" &
    "# Python wrapper around the C ABI declared in `" & libName & ".h`.\n" &
    "# Requires Python 3.8+ and the `cbor2` package (pip install cbor2).\n" & "\n" &
    "from __future__ import annotations\n" & "\n" & "import asyncio\n" &
    "import ctypes\n" & "import json\n" & "import os\n" & "import platform\n" &
    "import threading\n" & "from dataclasses import dataclass, field\n" &
    "from enum import IntEnum\n" &
    "from typing import Any, Callable, Dict, Generic, List, Optional, TypeVar\n" & "\n" &
    "import cbor2\n" & "\n\n"

  # Public-API interface summary, emitted right below the imports so the
  # file reads as a self-documenting overview before the implementation.
  # Same shape as the native Python wrapper's leading block — every
  # request method and every event subscribe / unsubscribe pair appears
  # with its full signature so a reader can scan the public surface
  # without diving into the body.
  py.add(
    "# ---------------------------------------------------------------------------\n"
  )
  py.add("# Public API surface (auto-generated from broker declarations)\n")
  py.add(
    "# ---------------------------------------------------------------------------\n"
  )
  py.add("# class " & className & ":\n")
  py.add("#   version() -> str    (@staticmethod)\n")
  py.add("#   __enter__() -> " & className & "\n")
  py.add("#   __exit__(*_) -> None\n")
  py.add("#   create_context() -> Result[None]\n")
  py.add("#   valid_context() -> bool\n")
  py.add("#   __bool__() -> bool\n")
  py.add("#   shutdown() -> None\n")
  py.add("#   ctx -> int    (property)\n")
  py.add("#\n")
  py.add("# Each request method returns Result[<TypeName>] (use .is_ok() / .value /\n")
  py.add("# .error). Each event has on_<name>(callback) -> handle and\n")
  py.add("# off_<name>(handle = 0) -> None.\n")
  py.add("#\n")
  for e in requestEntries:
    var sigParams = ""
    for i, (n, t) in e.argFields.pairs:
      if i > 0:
        sigParams.add(", ")
      sigParams.add(n & ": " & nimTypeToPyHint(t))
    py.add(
      "#   " & e.apiName & "(" & sigParams & ") -> Result[" & e.responseTypeName & "]\n"
    )
  for ev in eventEntries:
    py.add("#   on_" & ev.apiName & "(callback) -> int\n")
    py.add("#   off_" & ev.apiName & "(handle = 0) -> None\n")
  py.add("\n")

  # Library loading.
  py.add(
    "# ---------------------------------------------------------------------------\n"
  )
  py.add("# Shared library loading\n")
  py.add(
    "# ---------------------------------------------------------------------------\n\n"
  )
  py.add("def _resolve_library_path() -> str:\n")
  py.add("    here = os.path.dirname(os.path.abspath(__file__))\n")
  py.add("    sysname = platform.system()\n")
  py.add("    if sysname == \"Windows\":\n")
  py.add("        candidate = \"" & libName & ".dll\"\n")
  py.add("    elif sysname == \"Darwin\":\n")
  py.add("        candidate = \"lib" & libName & ".dylib\"\n")
  py.add("    else:\n")
  py.add("        candidate = \"lib" & libName & ".so\"\n")
  py.add("    return os.path.join(here, candidate)\n\n")
  py.add("_LIB = ctypes.CDLL(_resolve_library_path())\n\n")

  # C function signatures.
  py.add(
    "# ---------------------------------------------------------------------------\n"
  )
  py.add("# C ABI bindings\n")
  py.add(
    "# ---------------------------------------------------------------------------\n\n"
  )
  py.add("_LIB." & p & "version.argtypes = []\n")
  py.add("_LIB." & p & "version.restype = ctypes.c_char_p\n\n")
  py.add("_LIB." & p & "initialize.argtypes = []\n")
  py.add("_LIB." & p & "initialize.restype = None\n\n")
  py.add("_LIB." & p & "createContext.argtypes = [ctypes.POINTER(ctypes.c_char_p)]\n")
  py.add("_LIB." & p & "createContext.restype = ctypes.c_uint32\n\n")
  py.add("_LIB." & p & "shutdown.argtypes = [ctypes.c_uint32]\n")
  py.add("_LIB." & p & "shutdown.restype = ctypes.c_int32\n\n")
  # reduced-A: per-instance teardown (used by sub-wrapper close()).
  py.add("_LIB." & p & "releaseInstance.argtypes = [ctypes.c_uint32]\n")
  py.add("_LIB." & p & "releaseInstance.restype = ctypes.c_int32\n\n")
  py.add("_LIB." & p & "allocBuffer.argtypes = [ctypes.c_int32]\n")
  py.add("_LIB." & p & "allocBuffer.restype = ctypes.c_void_p\n\n")
  py.add("_LIB." & p & "freeBuffer.argtypes = [ctypes.c_void_p]\n")
  py.add("_LIB." & p & "freeBuffer.restype = None\n\n")
  py.add("_LIB." & p & "call.argtypes = [\n")
  py.add("    ctypes.c_uint32,\n")
  py.add("    ctypes.c_char_p,\n")
  py.add("    ctypes.c_void_p,\n")
  py.add("    ctypes.c_int32,\n")
  py.add("    ctypes.POINTER(ctypes.c_void_p),\n")
  py.add("    ctypes.POINTER(ctypes.c_int32),\n")
  py.add("]\n")
  py.add("_LIB." & p & "call.restype = ctypes.c_int32\n\n")

  # Event callback type used for both subscribe and the trampolines below.
  py.add("EVENT_CB_T = ctypes.CFUNCTYPE(\n")
  py.add("    None,\n")
  py.add("    ctypes.c_uint32,    # ctx\n")
  py.add("    ctypes.c_char_p,    # eventName\n")
  py.add("    ctypes.c_void_p,    # payloadBuf\n")
  py.add("    ctypes.c_int32,     # payloadLen\n")
  py.add("    ctypes.c_void_p,    # userData\n")
  py.add(")\n\n")
  py.add("_LIB." & p & "subscribe.argtypes = [\n")
  py.add("    ctypes.c_uint32,\n")
  py.add("    ctypes.c_char_p,\n")
  py.add("    EVENT_CB_T,\n")
  py.add("    ctypes.c_void_p,\n")
  py.add("]\n")
  py.add("_LIB." & p & "subscribe.restype = ctypes.c_uint64\n\n")
  py.add(
    "_LIB." & p &
      "unsubscribe.argtypes = [ctypes.c_uint32, ctypes.c_char_p, ctypes.c_uint64]\n"
  )
  py.add("_LIB." & p & "unsubscribe.restype = ctypes.c_int32\n\n")

  # ---- Async request gate (asyncio bridge) ----
  py.add("RESPONSE_CB_T = ctypes.CFUNCTYPE(\n")
  py.add("    None,\n")
  py.add("    ctypes.c_void_p,    # userData (our correlation token)\n")
  py.add("    ctypes.c_uint64,    # reqId\n")
  py.add("    ctypes.c_int32,     # status\n")
  py.add("    ctypes.c_void_p,    # respBuf\n")
  py.add("    ctypes.c_int32,     # respLen\n")
  py.add(")\n")
  py.add("_LIB." & p & "callAsync.argtypes = [\n")
  py.add("    ctypes.c_uint32,\n")
  py.add("    ctypes.c_char_p,\n")
  py.add("    ctypes.c_void_p,\n")
  py.add("    ctypes.c_int32,\n")
  py.add("    ctypes.c_uint64,\n")
  py.add("    ctypes.c_uint32,\n")
  py.add("    RESPONSE_CB_T,\n")
  py.add("    ctypes.c_void_p,\n")
  py.add("]\n")
  py.add("_LIB." & p & "callAsync.restype = ctypes.c_int32\n\n")

  py.add("# Max concurrent in-flight *_async calls per context; a full window\n")
  py.add("# makes an *_async method raise AsyncAgainError.\n")
  py.add("ASYNC_QUEUE_DEPTH = " & $asyncQueueDepth & "\n")
  py.add("# Library default dispatch timeout (ms) applied by *_async methods.\n")
  py.add("DEFAULT_ASYNC_TIMEOUT_MS = " & $asyncTimeoutMs & "\n\n")
  py.add("class AsyncAgainError(RuntimeError):\n")
  py.add(
    "    \"\"\"Raised by *_async when the async window is full (EAGAIN) — retry later.\"\"\"\n\n"
  )
  py.add("def _timeout_to_ms(timeout: Optional[float]) -> int:\n")
  py.add("    \"\"\"asyncio-style seconds -> ABI milliseconds.\n\n")
  py.add("    None -> library default; float('inf') -> 0 (infinite); else >= 1 ms.\n")
  py.add("    \"\"\"\n")
  py.add("    if timeout is None:\n")
  py.add("        return DEFAULT_ASYNC_TIMEOUT_MS\n")
  py.add("    if timeout == float(\"inf\"):\n")
  py.add("        return 0\n")
  py.add("    if timeout <= 0:\n")
  py.add(
    "        raise ValueError(\"timeout must be positive, None, or float('inf')\")\n"
  )
  py.add("    return max(1, int(timeout * 1000))\n\n")
  py.add("# Correlation registry: each in-flight *_async call gets an integer token\n")
  py.add("# passed to the C ABI as userData and handed back verbatim in the response\n")
  py.add("# callback (which runs on the library's delivery thread).\n")
  py.add("_async_lock = threading.Lock()\n")
  py.add("_async_registry: Dict[int, Any] = {}\n")
  py.add("_async_token = 0\n\n")
  py.add("def _async_register(loop: Any, fut: Any) -> int:\n")
  py.add("    global _async_token\n")
  py.add("    with _async_lock:\n")
  py.add("        _async_token += 1\n")
  py.add("        token = _async_token\n")
  py.add("        _async_registry[token] = (loop, fut)\n")
  py.add("        return token\n\n")
  py.add("def _async_unregister(token: int) -> None:\n")
  py.add("    with _async_lock:\n")
  py.add("        _async_registry.pop(token, None)\n\n")
  py.add("def _async_set(fut: Any, status: int, payload: bytes) -> None:\n")
  py.add("    if not fut.done():\n")
  py.add("        fut.set_result((status, payload))\n\n")
  py.add("def _async_status_message(status: int, payload: bytes) -> str:\n")
  py.add("    if status == " & $ApiStatusUnknownApi & " and payload:\n")
  py.add("        return payload.decode(\"utf-8\", errors=\"replace\")\n")
  py.add("    if status == " & $ApiStatusTimeout & ":\n")
  py.add("        return \"request timed out\"\n")
  py.add("    if status == " & $ApiStatusShutdown & ":\n")
  py.add("        return \"library shut down\"\n")
  py.add("    return f\"framework error: {status}\"\n\n")
  py.add(
    "def _async_response_trampoline(ud, req_id, status, resp_buf, resp_len):  # type: ignore[no-untyped-def]\n"
  )
  py.add("    token = ud if ud is not None else 0\n")
  py.add("    if token == 0:\n")
  py.add("        return\n")
  py.add("    with _async_lock:\n")
  py.add("        entry = _async_registry.pop(token, None)\n")
  py.add("    if entry is None:\n")
  py.add("        return\n")
  py.add("    loop, fut = entry\n")
  py.add("    payload = b\"\"\n")
  py.add("    if resp_buf and resp_len > 0:\n")
  py.add("        payload = ctypes.string_at(resp_buf, resp_len)\n")
  py.add("    try:\n")
  py.add("        loop.call_soon_threadsafe(_async_set, fut, int(status), payload)\n")
  py.add("    except RuntimeError:\n")
  py.add("        pass\n\n")
  py.add("# Kept alive at module scope so ctypes doesn't GC the C callback.\n")
  py.add("_ASYNC_RESPONSE_CB = RESPONSE_CB_T(_async_response_trampoline)\n\n")

  py.add(
    "_LIB." & p &
      "listApis.argtypes = [ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_int32)]\n"
  )
  py.add("_LIB." & p & "listApis.restype = ctypes.c_int32\n\n")
  py.add(
    "_LIB." & p &
      "getSchema.argtypes = [ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_int32)]\n"
  )
  py.add("_LIB." & p & "getSchema.restype = ctypes.c_int32\n\n")

  # Result helper.
  py.add(
    "# ---------------------------------------------------------------------------\n"
  )
  py.add("# Result[T]\n")
  py.add(
    "# ---------------------------------------------------------------------------\n\n"
  )
  py.add("T = TypeVar(\"T\")\n\n")
  py.add("@dataclass\n")
  py.add("class Result(Generic[T]):\n")
  py.add("    \"\"\"Mirror of Nim's Result[T, string] envelope on the wire.\n\n")
  py.add("    Use the `ok()` / `err()` factories to construct, never call\n")
  py.add("    the dataclass constructor directly.\n")
  py.add("    \"\"\"\n\n")
  py.add("    _ok: bool = False\n")
  py.add("    value: Optional[T] = None\n")
  py.add("    error: str = \"\"\n\n")
  py.add("    @classmethod\n")
  py.add("    def ok(cls, value: T) -> \"Result[T]\":\n")
  py.add("        return cls(_ok=True, value=value)\n\n")
  py.add("    @classmethod\n")
  py.add("    def err(cls, msg: str) -> \"Result[T]\":\n")
  py.add("        return cls(_ok=False, error=msg)\n\n")
  py.add("    def is_ok(self) -> bool:\n")
  py.add("        return self._ok\n\n")
  py.add("    def is_err(self) -> bool:\n")
  py.add("        return not self._ok\n\n")

  # ----- Enums (atkEnum) -------------------------------------------------
  var enumNames: seq[string] = @[]
  for entry in gApiTypeRegistry:
    if entry.kind == atkEnum:
      enumNames.add(entry.name)

  # ----- Distinct / alias (atkDistinct, atkAlias) ------------------------
  var aliasNames: seq[string] = @[]
  for entry in gApiTypeRegistry:
    if entry.kind in {atkDistinct, atkAlias}:
      aliasNames.add(entry.name)

  # ----- Object types (atkObject) — emit all registered, not just
  # response/event payload types, so seq[Tag] etc. resolve. -------------
  var objectNames: seq[string] = @[]
  for entry in gApiTypeRegistry:
    if entry.kind == atkObject and not entry.name.endsWith("CborArgs"):
      objectNames.add(entry.name)

  # A "scalar payload" is a primitive (non-object) broker type — `type X =
  # int32` — registered as a distinct alias of its underlying primitive.
  # Its CBOR wire value is a bare scalar; the Python surface uses the
  # `X = <prim>` alias directly. Such a type is an emittable request
  # response / event payload despite having no object fields.
  # Full mapper (not just primPyHint) so a container payload (`seq[string]`
  # -> list[str]) is an emittable scalar payload, not only primitives.
  proc isScalarPayload(name: string): bool {.compileTime.} =
    name.len > 0 and isTypeRegistered(name) and
      lookupTypeEntry(name).kind in {atkAlias, atkDistinct} and
      nimTypeToPyHint(resolveUnderlyingType(name)).len > 0

  proc isEmittablePayload(name: string): bool {.compileTime.} =
    name in objectNames or isScalarPayload(name)

  if enumNames.len > 0 or aliasNames.len > 0 or objectNames.len > 0:
    py.add(
      "# ---------------------------------------------------------------------------\n"
    )
    py.add("# Generated payload types\n")
    py.add(
      "# ---------------------------------------------------------------------------\n\n"
    )

  # Enums.
  for name in enumNames:
    let entry = lookupTypeEntry(name)
    py.add("class " & name & "(IntEnum):\n")
    if entry.enumValues.len == 0:
      py.add("    pass\n")
    else:
      for v in entry.enumValues:
        py.add("    " & v.name & " = " & $v.ordinal & "\n")
    py.add("\n")
    py.add("def _decode_" & name & "(data: Any) -> " & name & ":\n")
    py.add("    if isinstance(data, int):\n")
    py.add("        try:\n")
    py.add("            return " & name & "(data)\n")
    py.add("        except ValueError:\n")
    py.add("            return " & name & "(0)\n")
    py.add("    return " & name & "(0)\n\n")

  # Distinct / alias — Python alias of the underlying primitive plus
  # passthrough decode/encode helpers (so callers can freely use the
  # alias name in type hints).
  # The `Name = <pyType>` assignment is deferred until AFTER the object classes:
  # for a proc-sugar broker returning an object (`GetRow = RowData`) the RHS is a
  # class defined below, so a runtime assignment here would `NameError`. The
  # decode/encode helpers stay (their annotations are lazy via
  # `from __future__ import annotations`, and their bodies forward-ref fine).
  var aliasAssigns: seq[(string, string)] = @[]
  for name in aliasNames:
    let underlying = resolveUnderlyingType(name)
    let pyU = nimTypeToPyHint(underlying)
    if pyU.len == 0:
      py.add(
        "# TODO: alias '" & name & "' resolves to '" & underlying &
          "' which has no Python mapping\n\n"
      )
      continue
    aliasAssigns.add((name, pyU))
    py.add("def _decode_" & name & "(data: Any) -> " & pyU & ":\n")
    py.add("    return " & pyDecodeExpr(underlying, "data") & "\n\n")
    py.add("def _encode_" & name & "(v: Any) -> " & pyU & ":\n")
    py.add("    return " & pyEncodeExpr(underlying, "v") & "\n\n")

  # Objects: forward-declare names so per-type _decode/_encode helpers
  # can reference each other regardless of declaration order. Python
  # is lenient with forward refs inside def bodies, so emitting in
  # registry order is enough.
  for name in objectNames:
    let entry = lookupTypeEntry(name)
    py.add("@dataclass\n")
    py.add("class " & name & ":\n")
    var anyField = false
    for f in entry.fields:
      let hint = nimTypeToPyHint(f.nimType)
      if hint.len == 0:
        py.add("    # TODO: Nim type '" & f.nimType & "' not yet mappable\n")
        continue
      py.add(
        "    " & f.name & ": " & hint & " = " & nimTypeToPyDefault(f.nimType) & "\n"
      )
      anyField = true
    if not anyField:
      py.add("    pass\n")
    py.add("\n")

  # Deferred alias assignments (`GetRow = RowData`, `ContentTopic = str`, …),
  # now that any object RHS class is defined above. A bare-primitive response
  # payload is decoded as the simple type (its `_decode_<Verb>` helper still
  # exists), so its synthetic `Verb = bool` alias is dead — skip it; a field-used
  # alias (`ContentTopic`) is never a response name, so it stays.
  var responseNames: seq[string] = @[]
  for e in requestEntries:
    if e.responseTypeName.len > 0 and e.responseTypeName notin responseNames:
      responseNames.add(e.responseTypeName)
  var emittedAssign = false
  for (name, pyU) in aliasAssigns:
    if name in responseNames and effectiveResponsePayload(name) != name:
      continue
    py.add(name & " = " & pyU & "\n")
    emittedAssign = true
  if emittedAssign:
    py.add("\n")

  # Per-object _decode and _encode helpers.
  for name in objectNames:
    let entry = lookupTypeEntry(name)
    py.add("def _decode_" & name & "(data: Any) -> " & name & ":\n")
    py.add("    if not isinstance(data, dict):\n")
    py.add("        return " & name & "()\n")
    py.add("    return " & name & "(\n")
    for f in entry.fields:
      if not isPyMappable(f.nimType):
        continue
      let raw = "data.get(\"" & f.name & "\")"
      py.add("        " & f.name & "=" & pyDecodeExpr(f.nimType, raw) & ",\n")
    py.add("    )\n\n")

    py.add("def _encode_" & name & "(v: Any) -> Dict[str, Any]:\n")
    py.add("    if isinstance(v, dict):\n")
    py.add("        return v\n")
    py.add("    return {\n")
    for f in entry.fields:
      if not isPyMappable(f.nimType):
        continue
      py.add(
        "        \"" & f.name & "\": " & pyEncodeExpr(f.nimType, "v." & f.name) & ",\n"
      )
    py.add("    }\n\n")

  # Lib class.
  py.add(
    "# ---------------------------------------------------------------------------\n"
  )
  py.add("# Lib class\n")
  py.add(
    "# ---------------------------------------------------------------------------\n\n"
  )
  py.add("class " & className & ":\n")
  py.add("    \"\"\"Pythonic wrapper around the " & libName & " shared library.\n\n")
  py.add("    Usage::\n\n")
  py.add("        with " & className & "() as lib:\n")
  py.add("            init = lib.create_context()\n")
  py.add("            assert init.is_ok(), init.error\n")
  py.add("            r = lib.echo_request(\"ping\")\n")
  py.add("    \"\"\"\n\n")

  py.add("    @staticmethod\n")
  py.add("    def version() -> str:\n")
  py.add(
    "        \"\"\"Return the static semver string baked into the " & libName &
      " library.\"\"\"\n"
  )
  py.add("        raw = _LIB." & p & "version()\n")
  py.add("        return raw.decode(\"utf-8\") if raw else \"\"\n\n")

  # reduced-A: ownership predicates — an entry belongs to the main class when no
  # mainClass is designated (legacy single-class), or it is flat (no owning
  # interface), or its owning interface IS the main class.
  proc ownsReqMain(e: CborRequestEntry): bool =
    if mainClass.len == 0:
      return true
    let o = interfaceOwningRequestType(e.responseTypeName)
    o.len == 0 or o == mainClass

  proc ownsEvtMain(ev: CborEventEntry): bool =
    if mainClass.len == 0:
      return true
    let o = interfaceOwningEventType(ev.typeName)
    o.len == 0 or o == mainClass

  proc ownsSigMain(s: CborSignalEntry): bool =
    if mainClass.len == 0:
      return true
    let o = interfaceOwningSignalType(s.typeName)
    o.len == 0 or o == mainClass

  py.add("    def __init__(self) -> None:\n")
  py.add("        _LIB." & p & "initialize()\n")
  py.add("        self._ctx: int = 0\n")
  py.add("        # Per-event handler maps + GC-anchor for trampolines.\n")

  # Per-event handler maps, initialised in __init__ (main-class events only).
  for ev in eventEntries:
    if not isEmittablePayload(ev.typeName):
      continue
    if mainClass.len > 0 and not ownsEvtMain(ev):
      continue
    let mapName = "_" & ev.apiName & "_handlers"
    py.add("        self." & mapName & ": Dict[int, Any] = {}\n")
  py.add("\n")

  py.add("    def create_context(self) -> Result[None]:\n")
  py.add("        \"\"\"Create the library context. Result[None] — Result.ok(None)\n")
  py.add("        on success, Result.err(msg) on failure.\"\"\"\n")
  py.add("        if self._ctx != 0:\n")
  py.add("            return Result.err(\"Context already created\")\n")
  py.add("        err = ctypes.c_char_p()\n")
  py.add("        ctx = _LIB." & p & "createContext(ctypes.byref(err))\n")
  py.add("        if ctx == 0:\n")
  py.add(
    "            msg = err.value.decode(\"utf-8\", errors=\"replace\") if err.value else \"createContext returned 0\"\n"
  )
  py.add("            if err.value:\n")
  py.add("                _LIB." & p & "freeBuffer(err)\n")
  py.add("            return Result.err(msg)\n")
  py.add("        self._ctx = ctx\n")
  py.add("        return Result.ok(None)\n\n")

  py.add("    def valid_context(self) -> bool:\n")
  py.add("        return self._ctx != 0\n\n")
  py.add("    def __bool__(self) -> bool:\n")
  py.add("        return self.valid_context()\n\n")
  py.add("    @property\n")
  py.add("    def ctx(self) -> int:\n")
  py.add("        return self._ctx\n\n")
  py.add("    def shutdown(self) -> None:\n")
  py.add(
    "        \"\"\"Tear down the library context. Safe to call multiple times.\"\"\"\n"
  )
  py.add("        if self._ctx:\n")
  py.add("            _LIB." & p & "shutdown(self._ctx)\n")
  py.add("            self._ctx = 0\n")
  for ev in eventEntries:
    if not isEmittablePayload(ev.typeName):
      continue
    if mainClass.len > 0 and not ownsEvtMain(ev):
      continue
    let mapName = "_" & ev.apiName & "_handlers"
    py.add("        self." & mapName & ".clear()\n")
  py.add("\n")
  py.add("    def __enter__(self) -> \"" & className & "\":\n")
  py.add("        return self\n\n")
  py.add("    def __exit__(self, exc_type, exc, tb) -> None:\n")
  py.add("        self.shutdown()\n\n")
  py.add("    def __del__(self) -> None:\n")
  py.add("        try:\n")
  py.add("            self.shutdown()\n")
  py.add("        except Exception:\n")
  py.add("            pass\n\n")

  # Discovery API helpers (Phase 6).
  py.add("    def list_apis(self) -> Dict[str, Any]:\n")
  py.add("        \"\"\"Return the decoded ApiList describing the library surface.\n")
  py.add("        Returns a dict parsed from the JSON response.\n")
  py.add("        \"\"\"\n")
  py.add(
    "        return self._fetch_descriptor(_LIB." & p & "listApis, \"listApis\")\n\n"
  )
  py.add("    def get_schema(self) -> Dict[str, Any]:\n")
  py.add(
    "        \"\"\"Return the decoded LibraryDescriptor (schema + CDDL text).\"\"\"\n"
  )
  py.add(
    "        return self._fetch_descriptor(_LIB." & p & "getSchema, \"getSchema\")\n\n"
  )
  py.add("    def _fetch_descriptor(self, fn, label: str) -> Dict[str, Any]:\n")
  py.add("        resp_buf = ctypes.c_void_p()\n")
  py.add("        resp_len = ctypes.c_int32()\n")
  py.add("        status = fn(ctypes.byref(resp_buf), ctypes.byref(resp_len))\n")
  py.add("        if status != 0:\n")
  py.add("            raise RuntimeError(f\"{label} framework error: {status}\")\n")
  py.add("        if not resp_buf or resp_len.value <= 0:\n")
  py.add("            return {}\n")
  py.add("        try:\n")
  py.add("            payload = ctypes.string_at(resp_buf, resp_len.value)\n")
  py.add("        finally:\n")
  py.add("            _LIB." & p & "freeBuffer(resp_buf)\n")
  py.add("        return json.loads(payload.decode('utf-8'))\n\n")

  # Helper: do a sync call.
  py.add(
    "    def _do_call(self, api_name: str, req_payload: bytes) -> Optional[Dict[str, Any]]:\n"
  )
  py.add(
    "        \"\"\"Dispatch a CBOR request and return the decoded envelope dict,\n"
  )
  py.add("        or None on framework error (which raises a RuntimeError).\n")
  py.add("        \"\"\"\n")
  py.add("        in_buf = None\n")
  py.add("        if req_payload:\n")
  py.add("            in_buf = _LIB." & p & "allocBuffer(len(req_payload))\n")
  py.add("            if not in_buf:\n")
  py.add("                raise RuntimeError(\"allocBuffer failed\")\n")
  py.add("            ctypes.memmove(in_buf, req_payload, len(req_payload))\n")
  py.add("        resp_buf = ctypes.c_void_p()\n")
  py.add("        resp_len = ctypes.c_int32()\n")
  py.add("        status = _LIB." & p & "call(\n")
  py.add("            self._ctx,\n")
  py.add("            api_name.encode(\"utf-8\"),\n")
  py.add("            in_buf,\n")
  py.add("            len(req_payload),\n")
  py.add("            ctypes.byref(resp_buf),\n")
  py.add("            ctypes.byref(resp_len),\n")
  py.add("        )\n")
  py.add("        out: bytes = b\"\"\n")
  py.add("        if resp_buf and resp_len.value > 0:\n")
  py.add("            out = ctypes.string_at(resp_buf, resp_len.value)\n")
  py.add("            _LIB." & p & "freeBuffer(resp_buf)\n")
  py.add("        if status != 0:\n")
  py.add("            if status == " & $ApiStatusUnknownApi & " and out:\n")
  py.add(
    "                raise RuntimeError(out.decode(\"utf-8\", errors=\"replace\"))\n"
  )
  py.add("            raise RuntimeError(f\"framework error: {status}\")\n")
  py.add("        return cbor2.loads(out) if out else None\n\n")

  # `_do_signal`: slot-free one-way dispatch through `_call`. No response is
  # produced; status maps to None (accepted) or a distinguishable RuntimeError.
  py.add("    def _do_signal(self, api_name: str, req_payload: bytes) -> None:\n")
  py.add("        in_buf = None\n")
  py.add("        if req_payload:\n")
  py.add("            in_buf = _LIB." & p & "allocBuffer(len(req_payload))\n")
  py.add("            if not in_buf:\n")
  py.add("                raise RuntimeError(\"allocBuffer failed\")\n")
  py.add("            ctypes.memmove(in_buf, req_payload, len(req_payload))\n")
  py.add("        resp_buf = ctypes.c_void_p()\n")
  py.add("        resp_len = ctypes.c_int32()\n")
  py.add("        status = _LIB." & p & "call(\n")
  py.add("            self._ctx,\n")
  py.add("            api_name.encode(\"utf-8\"),\n")
  py.add("            in_buf,\n")
  py.add("            len(req_payload),\n")
  py.add("            ctypes.byref(resp_buf),\n")
  py.add("            ctypes.byref(resp_len),\n")
  py.add("        )\n")
  py.add("        if resp_buf and resp_len.value > 0:\n")
  py.add("            _LIB." & p & "freeBuffer(resp_buf)\n")
  py.add("        if status == 0:\n")
  py.add("            return\n")
  py.add(
    "        if status == " & $ApiStatusAgain &
      ":\n            raise RuntimeError(\"EAGAIN: signal queue full\")\n"
  )
  py.add(
    "        if status == " & $ApiStatusProviderErr &
      ":\n            raise RuntimeError(\"no signal handler installed\")\n"
  )
  py.add("        raise RuntimeError(f\"signal failed: {status}\")\n\n")

  # `_call_async`: fire-and-forget dispatch. Allocates the library input buffer
  # (the C ABI frees it), passes the correlation token as userData, and returns
  # the raw rc (0 queued; negative not queued — callback will not fire).
  py.add(
    "    def _call_async(self, api_name: str, req_payload: bytes, token: int, timeout_ms: int) -> int:\n"
  )
  py.add("        in_buf = None\n")
  py.add("        if req_payload:\n")
  py.add("            in_buf = _LIB." & p & "allocBuffer(len(req_payload))\n")
  py.add("            if not in_buf:\n")
  py.add("                raise RuntimeError(\"allocBuffer failed\")\n")
  py.add("            ctypes.memmove(in_buf, req_payload, len(req_payload))\n")
  py.add("        return _LIB." & p & "callAsync(\n")
  py.add("            self._ctx,\n")
  py.add("            api_name.encode(\"utf-8\"),\n")
  py.add("            in_buf,\n")
  py.add("            len(req_payload),\n")
  py.add("            token,\n")
  py.add("            timeout_ms,\n")
  py.add("            _ASYNC_RESPONSE_CB,\n")
  py.add("            ctypes.c_void_p(token),\n")
  py.add("        )\n\n")

  # reduced-A: a request method's body, indented for a wrapper class. Handles
  # both normal requests (decode the typed payload) and instance-returning
  # requests (Ok value is a uint32 ctx → construct the typed sub-wrapper).
  # Reused by the main class and each sub-interface class.
  proc emitReqMethod(e: CborRequestEntry): string =
    if e.responseTypeName.len == 0:
      return ""
    var argsMappable = true
    for (n, t) in e.argFields:
      if not isPyMappable(t):
        argsMappable = false
        break
    if e.returnsInterface.len > 0:
      if not argsMappable:
        return "    # TODO: '" & e.apiName & "' has unmappable parameter types.\n\n"
      let sub = subClassName(e.returnsInterface)
      var sigParams = "self"
      var argsDictBuilder = "{}"
      if e.argFields.len > 0:
        var dictParts = ""
        for i, (n, t) in e.argFields.pairs:
          sigParams.add(", " & n & ": " & nimTypeToPyHint(t))
          if i > 0:
            dictParts.add(", ")
          dictParts.add("\"" & n & "\": " & pyEncodeExpr(t, n))
        argsDictBuilder = "{" & dictParts & "}"
      result.add(
        "    def " & e.apiName & "(" & sigParams & ") -> Result[\"" & sub & "\"]:\n"
      )
      result.add("        if self._ctx == 0:\n")
      result.add("            return Result.err(\"Library context is not created\")\n")
      if e.argFields.len > 0:
        result.add("        req_payload = cbor2.dumps(" & argsDictBuilder & ")\n")
      else:
        result.add("        req_payload = b\"\"\n")
      result.add(
        "        try:\n" & "            envelope = self._do_call(\"" & e.apiName &
          "\", req_payload)\n" & "        except RuntimeError as exc:\n" &
          "            return Result.err(str(exc))\n"
      )
      result.add(
        "        if envelope is None or not isinstance(envelope, dict):\n" &
          "            return Result.err(\"empty or malformed response envelope\")\n" &
          "        if envelope.get(\"err\") is not None:\n" &
          "            return Result.err(str(envelope[\"err\"]))\n" &
          "        return Result.ok(" & sub & "(int(envelope.get(\"ok\"))))\n\n"
      )
      return result
    if not isEmittablePayload(e.responseTypeName):
      return
        "    # TODO: '" & e.apiName & "' return type '" & e.responseTypeName &
        "' is not a registered object type.\n\n"
    if not argsMappable:
      return
        "    # TODO: '" & e.apiName &
        "' has parameters whose Nim types aren't yet mappable to Python.\n\n"
    let methodName = e.apiName
    var sigParams = "self"
    var argsDictBuilder = "{}"
    if e.argFields.len > 0:
      var dictParts = ""
      for i, (n, t) in e.argFields.pairs:
        sigParams.add(", " & n & ": " & nimTypeToPyHint(t))
        if i > 0:
          dictParts.add(", ")
        dictParts.add("\"" & n & "\": " & pyEncodeExpr(t, n))
      argsDictBuilder = "{" & dictParts & "}"
    result.add(
      "    def " & methodName & "(" & sigParams & ") -> Result[" & e.responseTypeName &
        "]:\n"
    )
    result.add("        if self._ctx == 0:\n")
    result.add("            return Result.err(\"Library context is not created\")\n")
    if e.argFields.len > 0:
      result.add("        req_payload = cbor2.dumps(" & argsDictBuilder & ")\n")
    else:
      result.add("        req_payload = b\"\"\n")
    result.add(
      "        try:\n" & "            envelope = self._do_call(\"" & e.apiName &
        "\", req_payload)\n" & "        except RuntimeError as exc:\n" &
        "            return Result.err(str(exc))\n"
    )
    result.add(
      "        if envelope is None or not isinstance(envelope, dict):\n" &
        "            return Result.err(\"empty or malformed response envelope\")\n" &
        "        if envelope.get(\"err\") is not None:\n" &
        "            return Result.err(str(envelope[\"err\"]))\n" &
        "        return Result.ok(_decode_" & e.responseTypeName &
        "(envelope.get(\"ok\")))\n\n"
    )

  # Async sibling: `await lib.<method>_async(args) -> Result[T]`. Bridges the C
  # response callback to an asyncio.Future via call_soon_threadsafe. EAGAIN (-6)
  # raises AsyncAgainError; -12/-11 + provider errors come back as Result.err.
  proc emitAsyncReqMethod(e: CborRequestEntry): string =
    if e.responseTypeName.len == 0:
      return ""
    if e.returnsInterface.len > 0:
      return "" # create-instance methods stay sync-only
    if not isEmittablePayload(e.responseTypeName):
      return ""
    for (n, t) in e.argFields:
      if not isPyMappable(t):
        return ""
    let methodName = e.apiName
    var sigParams = "self"
    var argsDictBuilder = "{}"
    if e.argFields.len > 0:
      var dictParts = ""
      for i, (n, t) in e.argFields.pairs:
        sigParams.add(", " & n & ": " & nimTypeToPyHint(t))
        if i > 0:
          dictParts.add(", ")
        dictParts.add("\"" & n & "\": " & pyEncodeExpr(t, n))
      argsDictBuilder = "{" & dictParts & "}"
    # asyncio idiom: `timeout` in SECONDS (None -> lib default, inf -> none);
    # -12 raises TimeoutError (like asyncio.wait_for); backpressure AWAITS on a
    # per-instance Semaphore(ASYNC_QUEUE_DEPTH) instead of throwing, so
    # `asyncio.gather(*many)` pipelines beyond the window transparently.
    # AsyncAgainError remains only for the residual cross-process -6.
    result.add(
      "    async def " & methodName & "_async(" & sigParams &
        ", timeout: Optional[float] = None) -> Result[" & e.responseTypeName & "]:\n"
    )
    result.add("        if self._ctx == 0:\n")
    result.add("            return Result.err(\"Library context is not created\")\n")
    result.add("        timeout_ms = _timeout_to_ms(timeout)\n")
    result.add("        # Lazy per-instance window semaphore (bound to the running\n")
    result.add("        # loop on first await; one loop per wrapper instance).\n")
    result.add("        sem = getattr(self, \"_async_sem\", None)\n")
    result.add("        if sem is None:\n")
    result.add("            sem = asyncio.Semaphore(ASYNC_QUEUE_DEPTH)\n")
    result.add("            self._async_sem = sem\n")
    if e.argFields.len > 0:
      result.add("        req_payload = cbor2.dumps(" & argsDictBuilder & ")\n")
    else:
      result.add("        req_payload = b\"\"\n")
    result.add("        async with sem:\n")
    result.add("            loop = asyncio.get_running_loop()\n")
    result.add("            fut = loop.create_future()\n")
    result.add("            token = _async_register(loop, fut)\n")
    result.add("            try:\n")
    result.add(
      "                rc = self._call_async(\"" & methodName &
        "\", req_payload, token, timeout_ms)\n"
    )
    result.add("            except RuntimeError as exc:\n")
    result.add("                _async_unregister(token)\n")
    result.add("                return Result.err(str(exc))\n")
    result.add("            if rc != 0:\n")
    result.add("                _async_unregister(token)\n")
    result.add("                if rc == " & $ApiStatusAgain & ":\n")
    result.add(
      "                    # The semaphore bounds this instance to the window;\n"
    )
    result.add(
      "                    # -6 here means another client shares the context.\n"
    )
    result.add("                    raise AsyncAgainError(\"async window full\")\n")
    result.add("                return Result.err(f\"framework error: {rc}\")\n")
    result.add("            status, resp = await fut\n")
    result.add("        if status == " & $ApiStatusTimeout & ":\n")
    result.add("            raise TimeoutError(\n")
    result.add(
      "                f\"" & methodName & " timed out after {timeout_ms} ms\"\n"
    )
    result.add("            )\n")
    result.add("        if status != 0:\n")
    result.add("            return Result.err(_async_status_message(status, resp))\n")
    result.add("        if not resp:\n")
    result.add(
      "            return Result.err(\"empty or malformed response envelope\")\n"
    )
    result.add("        envelope = cbor2.loads(resp)\n")
    result.add("        if not isinstance(envelope, dict):\n")
    result.add(
      "            return Result.err(\"empty or malformed response envelope\")\n"
    )
    result.add("        if envelope.get(\"err\") is not None:\n")
    result.add("            return Result.err(str(envelope[\"err\"]))\n")
    result.add(
      "        return Result.ok(_decode_" & e.responseTypeName &
        "(envelope.get(\"ok\")))\n\n"
    )

  # Per-request typed methods (main class).
  for e in requestEntries:
    if not ownsReqMain(e):
      continue
    py.add(emitReqMethod(e))
    py.add(emitAsyncReqMethod(e))

  # Per-signal one-way methods: `def <name>(self, fields...) -> None`, raising a
  # distinguishable RuntimeError on backpressure / no-handler. No async sibling.
  proc emitSignalMethod(s: CborSignalEntry): string =
    if not isEmittablePayload(s.typeName):
      return
        "    # TODO: signal '" & s.apiName & "' payload '" & s.typeName &
        "' is not a registered type.\n\n"
    var fields: seq[ApiFieldDef]
    if s.typeName in objectNames:
      fields = lookupTypeEntry(s.typeName).fields
    else:
      fields = @[ApiFieldDef(name: "value", nimType: resolveUnderlyingType(s.typeName))]
    for f in fields:
      if not isPyMappable(f.nimType):
        return
          "    # TODO: signal '" & s.apiName &
          "' has fields whose Nim types aren't yet mappable to Python.\n\n"
    var sigParams = "self"
    var dictParts = ""
    for i, f in fields.pairs:
      sigParams.add(", " & f.name & ": " & nimTypeToPyHint(f.nimType))
      if i > 0:
        dictParts.add(", ")
      dictParts.add("\"" & f.name & "\": " & pyEncodeExpr(f.nimType, f.name))
    result.add("    def " & s.apiName & "(" & sigParams & ") -> None:\n")
    result.add("        if self._ctx == 0:\n")
    result.add("            raise RuntimeError(\"Library context is not created\")\n")
    if fields.len == 0:
      result.add("        req_payload = b\"\"\n")
    elif s.typeName in objectNames:
      result.add("        req_payload = cbor2.dumps({" & dictParts & "})\n")
    else:
      result.add(
        "        req_payload = cbor2.dumps(" &
          pyEncodeExpr(fields[0].nimType, fields[0].name) & ")\n"
      )
    result.add("        self._do_signal(\"" & s.apiName & "\", req_payload)\n\n")

  for s in signalEntries:
    if not ownsSigMain(s):
      continue
    py.add(emitSignalMethod(s))

  # Per-event subscribe / unsubscribe (main-class events only).
  for ev in eventEntries:
    if not ownsEvtMain(ev):
      continue
    if not isEmittablePayload(ev.typeName):
      py.add(
        "    # TODO: event '" & ev.apiName & "' payload type '" & ev.typeName &
          "' is not a registered object type.\n\n"
      )
      continue
    let mapName = "_" & ev.apiName & "_handlers"
    let onName = "on_" & ev.apiName
    let offName = "off_" & ev.apiName

    # Build per-field type hints + per-field destructure args. The user
    # callback signature is `(<ClassName>, *unpacked_field_types) -> None`
    # — parity with the C++ wrapper and the native-FFI Python wrapper.
    var hintParts: seq[string] = @[className]
    var destructureArgs: seq[string] = @["self"]
    if isScalarPayload(ev.typeName):
      # Scalar payload: the decoded `evt` IS the value — one bare arg.
      hintParts.add(primPyHint(resolveUnderlyingType(ev.typeName)))
      destructureArgs.add("evt")
    else:
      for f in lookupTypeEntry(ev.typeName).fields:
        hintParts.add(nimTypeToPyHint(f.nimType))
        destructureArgs.add("evt." & f.name)
    let pyCallableHint = "Callable[[" & hintParts.join(", ") & "], None]"

    py.add("    def " & onName & "(self, callback: " & pyCallableHint & ") -> int:\n")
    py.add(
      "        \"\"\"Subscribe to '" & ev.apiName &
        "' events. Returns a handle (>=2) on success, 0 on failure.\n"
    )
    py.add("        The callback receives the owning library instance as its\n")
    py.add("        first argument followed by the unpacked event payload\n")
    py.add("        fields.\"\"\"\n")
    py.add("        if self._ctx == 0:\n")
    py.add("            return 0\n")
    py.add("        def trampoline(\n")
    py.add("            ctx: int, name: bytes, buf: int, buf_len: int, _ud: int\n")
    py.add("        ) -> None:\n")
    py.add("            if not buf or buf_len <= 0:\n")
    py.add("                return\n")
    py.add("            try:\n")
    py.add("                payload = ctypes.string_at(buf, buf_len)\n")
    py.add("                data = cbor2.loads(payload)\n")
    py.add("                evt = _decode_" & ev.typeName & "(data)\n")
    py.add("                callback(" & destructureArgs.join(", ") & ")\n")
    py.add("            except Exception:\n")
    py.add("                # Swallow handler errors so they don't escape\n")
    py.add("                # back across the C ABI boundary.\n")
    py.add("                pass\n")
    py.add("        cb = EVENT_CB_T(trampoline)\n")
    py.add(
      "        h = _LIB." & p & "subscribe(self._ctx, b\"" & ev.apiName &
        "\", cb, None)\n"
    )
    py.add("        if h == 0 or h == 1:\n")
    py.add("            return h\n")
    py.add("        # Hold a reference to both the CFUNCTYPE wrapper and the\n")
    py.add("        # user callback — without this the Python GC would free\n")
    py.add("        # the trampoline before the C side fires it.\n")
    py.add("        self." & mapName & "[h] = (cb, callback)\n")
    py.add("        return h\n\n")

    py.add("    def " & offName & "(self, handle: int = 0) -> None:\n")
    py.add(
      "        \"\"\"Unsubscribe from '" & ev.apiName &
        "' events. handle=0 removes all.\"\"\"\n"
    )
    py.add("        if self._ctx == 0:\n")
    py.add("            return\n")
    py.add(
      "        _LIB." & p & "unsubscribe(self._ctx, b\"" & ev.apiName & "\", handle)\n"
    )
    py.add("        if handle == 0:\n")
    py.add("            self." & mapName & ".clear()\n")
    py.add("        else:\n")
    py.add("            self." & mapName & ".pop(handle, None)\n\n")

  # reduced-A: per-sub-interface wrapper classes. Each non-main
  # BrokerInterface(API) with at least one request entry gets its own class. A
  # sub-instance is created by a main create-instance method (returns Result of
  # the sub class), bound to its routing ctx. The sub class shares the single C
  # ABI: its _do_call uses self._ctx, which the library routes by classCtx to
  # the same processing thread. close() calls <lib>_releaseInstance(ctx).
  if mainClass.len > 0:
    # Collect distinct non-main owning interfaces directly from the entries.
    # (Deriving from interfaceOwningRequestType avoids returning the compile-
    # time registry seq by value, which the Nim VM aliases to an empty copy.)
    var subNames: seq[string] = @[]
    for e in requestEntries:
      let o = interfaceOwningRequestType(e.responseTypeName)
      if o.len > 0 and o != mainClass and o notin subNames:
        subNames.add(o)
    for ifaceName in subNames:
      var ifaceReqs: seq[CborRequestEntry] = @[]
      for e in requestEntries:
        if interfaceOwningRequestType(e.responseTypeName) == ifaceName:
          ifaceReqs.add(e)
      if ifaceReqs.len == 0:
        continue
      let sub = subClassName(ifaceName)
      py.add(
        "# ---------------------------------------------------------------------------\n"
      )
      py.add(
        "# " & sub & " — sub-instance wrapper (created via a " & mainClass &
          " request)\n"
      )
      py.add(
        "# ---------------------------------------------------------------------------\n\n"
      )
      py.add("class " & sub & ":\n")
      py.add("    \"\"\"Sub-interface instance of " & ifaceName & ".\n\n")
      py.add("    Lives on the library's processing thread; obtained from a main\n")
      py.add("    create-instance method. Call close() (or use as a context\n")
      py.add("    manager) to release it — drops its providers/listeners.\"\"\"\n\n")
      py.add("    def __init__(self, ctx: int) -> None:\n")
      py.add("        self._ctx: int = ctx\n")
      # Initialize per-event handler maps for sub-interface events.
      for ev in eventEntries:
        if interfaceOwningEventType(ev.typeName) != ifaceName:
          continue
        if not isEmittablePayload(ev.typeName):
          continue
        let mapName = "_" & ev.apiName & "_handlers"
        py.add("        self." & mapName & ": Dict[int, Any] = {}\n")
      py.add("\n")
      py.add("    @property\n")
      py.add("    def ctx(self) -> int:\n")
      py.add("        return self._ctx\n\n")
      py.add("    def valid(self) -> bool:\n")
      py.add("        return self._ctx != 0\n\n")
      py.add("    def __bool__(self) -> bool:\n")
      py.add("        return self._ctx != 0\n\n")
      # _do_call (same body as the main class; routes by self._ctx).
      py.add(
        "    def _do_call(self, api_name: str, req_payload: bytes) -> Optional[Dict[str, Any]]:\n"
      )
      py.add("        in_buf = None\n")
      py.add("        if req_payload:\n")
      py.add("            in_buf = _LIB." & p & "allocBuffer(len(req_payload))\n")
      py.add("            if not in_buf:\n")
      py.add("                raise RuntimeError(\"allocBuffer failed\")\n")
      py.add("            ctypes.memmove(in_buf, req_payload, len(req_payload))\n")
      py.add("        resp_buf = ctypes.c_void_p()\n")
      py.add("        resp_len = ctypes.c_int32()\n")
      py.add("        status = _LIB." & p & "call(\n")
      py.add("            self._ctx,\n")
      py.add("            api_name.encode(\"utf-8\"),\n")
      py.add("            in_buf,\n")
      py.add("            len(req_payload),\n")
      py.add("            ctypes.byref(resp_buf),\n")
      py.add("            ctypes.byref(resp_len),\n")
      py.add("        )\n")
      py.add("        out: bytes = b\"\"\n")
      py.add("        if resp_buf and resp_len.value > 0:\n")
      py.add("            out = ctypes.string_at(resp_buf, resp_len.value)\n")
      py.add("            _LIB." & p & "freeBuffer(resp_buf)\n")
      py.add("        if status != 0:\n")
      py.add("            if status == " & $ApiStatusUnknownApi & " and out:\n")
      py.add(
        "                raise RuntimeError(out.decode(\"utf-8\", errors=\"replace\"))\n"
      )
      py.add("            raise RuntimeError(f\"framework error: {status}\")\n")
      py.add("        return cbor2.loads(out) if out else None\n\n")
      py.add(
        "    def _call_async(self, api_name: str, req_payload: bytes, token: int, timeout_ms: int) -> int:\n"
      )
      py.add("        in_buf = None\n")
      py.add("        if req_payload:\n")
      py.add("            in_buf = _LIB." & p & "allocBuffer(len(req_payload))\n")
      py.add("            if not in_buf:\n")
      py.add("                raise RuntimeError(\"allocBuffer failed\")\n")
      py.add("            ctypes.memmove(in_buf, req_payload, len(req_payload))\n")
      py.add("        return _LIB." & p & "callAsync(\n")
      py.add("            self._ctx,\n")
      py.add("            api_name.encode(\"utf-8\"),\n")
      py.add("            in_buf,\n")
      py.add("            len(req_payload),\n")
      py.add("            token,\n")
      py.add("            timeout_ms,\n")
      py.add("            _ASYNC_RESPONSE_CB,\n")
      py.add("            ctypes.c_void_p(token),\n")
      py.add("        )\n\n")
      # Sub-interface one-way signals (routed by self._ctx — the sub-instance
      # ctx — so the handler installed under that ctx runs). Emit the _do_signal
      # helper only when this sub-interface owns at least one signal.
      var ifaceSigs: seq[CborSignalEntry] = @[]
      for s in signalEntries:
        if interfaceOwningSignalType(s.typeName) == ifaceName:
          ifaceSigs.add(s)
      if ifaceSigs.len > 0:
        py.add("    def _do_signal(self, api_name: str, req_payload: bytes) -> None:\n")
        py.add("        in_buf = None\n")
        py.add("        if req_payload:\n")
        py.add("            in_buf = _LIB." & p & "allocBuffer(len(req_payload))\n")
        py.add("            if not in_buf:\n")
        py.add("                raise RuntimeError(\"allocBuffer failed\")\n")
        py.add("            ctypes.memmove(in_buf, req_payload, len(req_payload))\n")
        py.add("        resp_buf = ctypes.c_void_p()\n")
        py.add("        resp_len = ctypes.c_int32()\n")
        py.add("        status = _LIB." & p & "call(\n")
        py.add("            self._ctx,\n")
        py.add("            api_name.encode(\"utf-8\"),\n")
        py.add("            in_buf,\n")
        py.add("            len(req_payload),\n")
        py.add("            ctypes.byref(resp_buf),\n")
        py.add("            ctypes.byref(resp_len),\n")
        py.add("        )\n")
        py.add("        if resp_buf and resp_len.value > 0:\n")
        py.add("            _LIB." & p & "freeBuffer(resp_buf)\n")
        py.add("        if status == 0:\n")
        py.add("            return\n")
        py.add(
          "        if status == " & $ApiStatusAgain &
            ":\n            raise RuntimeError(\"EAGAIN: signal queue full\")\n"
        )
        py.add(
          "        if status == " & $ApiStatusProviderErr &
            ":\n            raise RuntimeError(\"no signal handler installed\")\n"
        )
        py.add("        raise RuntimeError(f\"signal failed: {status}\")\n\n")
      for s in ifaceSigs:
        py.add(emitSignalMethod(s))
      for e in ifaceReqs:
        py.add(emitReqMethod(e))
        py.add(emitAsyncReqMethod(e))
      # Sub-interface event methods (subscribe/unsubscribe keyed by self._ctx).
      for ev in eventEntries:
        if interfaceOwningEventType(ev.typeName) != ifaceName:
          continue
        if not isEmittablePayload(ev.typeName):
          py.add(
            "    # TODO: event '" & ev.apiName & "' payload type '" & ev.typeName &
              "' is not a registered object type.\n\n"
          )
          continue
        let mapName = "_" & ev.apiName & "_handlers"
        let onName = "on_" & ev.apiName
        let offName = "off_" & ev.apiName
        var hintParts: seq[string] = @[sub]
        var destructureArgs: seq[string] = @["self"]
        if isScalarPayload(ev.typeName):
          hintParts.add(primPyHint(resolveUnderlyingType(ev.typeName)))
          destructureArgs.add("evt")
        else:
          for f in lookupTypeEntry(ev.typeName).fields:
            hintParts.add(nimTypeToPyHint(f.nimType))
            destructureArgs.add("evt." & f.name)
        let pyCallableHint = "Callable[[" & hintParts.join(", ") & "], None]"
        py.add(
          "    def " & onName & "(self, callback: " & pyCallableHint & ") -> int:\n"
        )
        py.add(
          "        \"\"\"Subscribe to '" & ev.apiName &
            "' events. Returns a handle (>=2) on success, 0 on failure.\"\"\"\n"
        )
        py.add("        if self._ctx == 0:\n")
        py.add("            return 0\n")
        py.add("        def trampoline(\n")
        py.add("            ctx: int, name: bytes, buf: int, buf_len: int, _ud: int\n")
        py.add("        ) -> None:\n")
        py.add("            if not buf or buf_len <= 0:\n")
        py.add("                return\n")
        py.add("            try:\n")
        py.add("                payload = ctypes.string_at(buf, buf_len)\n")
        py.add("                data = cbor2.loads(payload)\n")
        py.add("                evt = _decode_" & ev.typeName & "(data)\n")
        py.add("                callback(" & destructureArgs.join(", ") & ")\n")
        py.add("            except Exception:\n")
        py.add("                pass\n")
        py.add("        cb = EVENT_CB_T(trampoline)\n")
        py.add(
          "        h = _LIB." & p & "subscribe(self._ctx, b\"" & ev.apiName &
            "\", cb, None)\n"
        )
        py.add("        if h == 0 or h == 1:\n")
        py.add("            return h\n")
        py.add("        self." & mapName & "[h] = (cb, callback)\n")
        py.add("        return h\n\n")
        py.add("    def " & offName & "(self, handle: int = 0) -> None:\n")
        py.add(
          "        \"\"\"Unsubscribe from '" & ev.apiName &
            "' events. handle=0 removes all.\"\"\"\n"
        )
        py.add("        if self._ctx == 0:\n")
        py.add("            return\n")
        py.add(
          "        _LIB." & p & "unsubscribe(self._ctx, b\"" & ev.apiName &
            "\", handle)\n"
        )
        py.add("        if handle == 0:\n")
        py.add("            self." & mapName & ".clear()\n")
        py.add("        else:\n")
        py.add("            self." & mapName & ".pop(handle, None)\n\n")
      py.add("    def close(self) -> None:\n")
      py.add("        \"\"\"Release this sub-instance (idempotent).\"\"\"\n")
      py.add("        if self._ctx:\n")
      py.add("            _LIB." & p & "releaseInstance(self._ctx)\n")
      py.add("            self._ctx = 0\n")
      for ev in eventEntries:
        if interfaceOwningEventType(ev.typeName) != ifaceName:
          continue
        if not isEmittablePayload(ev.typeName):
          continue
        let mapName = "_" & ev.apiName & "_handlers"
        py.add("        self." & mapName & ".clear()\n")
      py.add("\n")
      py.add("    def __enter__(self) -> \"" & sub & "\":\n")
      py.add("        return self\n\n")
      py.add("    def __exit__(self, exc_type, exc, tb) -> None:\n")
      py.add("        self.close()\n\n")
      py.add("    def __del__(self) -> None:\n")
      py.add("        try:\n")
      py.add("            self.close()\n")
      py.add("        except Exception:\n")
      py.add("            pass\n\n")

  try:
    writeFile(pyPath, py)
  except IOError:
    error(
      "Failed to write generated CBOR Python wrapper '" & pyPath & "': " &
        getCurrentExceptionMsg()
    )

{.push raises: [].}
{.pop.}
