## Runtime marshal / unmarshal helpers for (mt) broker payloads.
##
## The broker macro emits two thin per-type wrappers
## (`<TypeName>MtMarshal` / `<TypeName>MtUnmarshal`) that call into the
## generic `mtMarshalValue` / `mtUnmarshalValue` defined here. Those
## generics use `when supportsCopyMem(T):` + Nim's `fieldPairs` to walk
## arbitrary payload types at compile time, recursing into:
##
##   - **POD types** (scalars, enums, distinct-of-POD, fixed POD arrays,
##     objects whose fields are all POD): single `copyMem(sizeof(T))`.
##     `supportsCopyMem` correctly classifies all of these.
##   - **`string`**: 4-byte little-endian length + bytes.
##   - **`seq[U]`**: 4-byte length + per-element recursive marshal.
##   - **`array[N, U]` where U is non-POD**: per-element recursive marshal.
##   - **objects with non-POD fields**: `fieldPairs` walks each field
##     recursively.
##
## Forbidden (caught at the call site by a compile-time `{.error.}`):
##   `ref T`, `ptr T`, `pointer`, `cstring`, proc-typed fields.
##
## Strings and seqs allocate on the *consumer thread's GC heap* during
## unmarshal — no thread-local pointer ever crosses a broker boundary,
## which is the §2.6 fix in practice.

{.push raises: [].}

import std/[macros, typetraits]

# Generic recursive primitives. The `pos` parameter is updated in place;
# the bool return is false on overflow / truncation / malformed input.

proc mtMarshalValue*[T](
  buf: ptr UncheckedArray[byte], cap: int, value: T, pos: var int
): bool {.gcsafe.}

proc mtUnmarshalValue*[T](
  buf: ptr UncheckedArray[byte], len: int, value: var T, pos: var int
): bool {.gcsafe.}

# Sequence specialization — separate generic so the element type `U`
# is statically known (we need `newSeq[U]` on the unmarshal side).

proc mtMarshalSeq*[U](
    buf: ptr UncheckedArray[byte], cap: int, value: openArray[U], pos: var int
): bool {.gcsafe.} =
  mixin mtMarshalValue # allow user overloads for element type
  if pos + 4 > cap:
    return false
  let sLen = uint32(value.len)
  copyMem(addr buf[pos], unsafeAddr sLen, 4)
  pos += 4
  when supportsCopyMem(U):
    let totalBytes = int(sLen) * sizeof(U)
    if pos + totalBytes > cap:
      return false
    if sLen > 0'u32:
      copyMem(addr buf[pos], unsafeAddr value[0], totalBytes)
    pos += totalBytes
    return true
  else:
    for e in value:
      if not mtMarshalValue(buf, cap, e, pos):
        return false
    return true

proc mtUnmarshalSeq*[U](
    buf: ptr UncheckedArray[byte], len: int, value: var seq[U], pos: var int
): bool {.gcsafe.} =
  mixin mtUnmarshalValue # allow user overloads for element type
  if pos + 4 > len:
    return false
  var sLen: uint32
  copyMem(addr sLen, addr buf[pos], 4)
  pos += 4
  when supportsCopyMem(U):
    let totalBytes = int(sLen) * sizeof(U)
    if pos + totalBytes > len:
      return false
    value = newSeq[U](int(sLen))
    if sLen > 0'u32:
      copyMem(addr value[0], addr buf[pos], totalBytes)
    pos += totalBytes
    return true
  else:
    value = newSeq[U](int(sLen))
    for i in 0 ..< int(sLen):
      if not mtUnmarshalValue(buf, len, value[i], pos):
        return false
    return true

proc mtMarshalValue*[T](
    buf: ptr UncheckedArray[byte], cap: int, value: T, pos: var int
): bool {.gcsafe.} =
  mixin mtMarshalValue # allow user overloads for field types
  when T is ref:
    when compiles(value.brokerCtx):
      # reduced-A: a BrokerInterface ref is a same-thread routing handle (it
      # carries a `brokerCtx`). Create-instance dispatch is same-thread (adapter
      # + provider both on the processing thread), so the ref never actually
      # travels between threads — we marshal its pointer bytewise purely to
      # satisfy the response codec's instantiation. This is NOT general
      # cross-thread ref support; arbitrary refs still hard-error below.
      if pos + sizeof(pointer) > cap:
        return false
      copyMem(addr buf[pos], unsafeAddr value, sizeof(pointer))
      pos += sizeof(pointer)
      return true
    else:
      {.error: "mt broker payload field type is unsupported (ref T): " & $T.}
  # ptr / pointer / cstring fall through to the `supportsCopyMem` branch
  # below and are marshaled bytewise. Caller is responsible for the
  # lifetime of what they point to — typically used for shared structures
  # like chronos' ThreadSignalPtr.
  elif supportsCopyMem(T):
    if pos + sizeof(T) > cap:
      return false
    copyMem(addr buf[pos], unsafeAddr value, sizeof(T))
    pos += sizeof(T)
    return true
  elif T is string:
    let sLen = uint32(value.len)
    if pos + 4 + int(sLen) > cap:
      return false
    copyMem(addr buf[pos], unsafeAddr sLen, 4)
    pos += 4
    if sLen > 0'u32:
      copyMem(addr buf[pos], unsafeAddr value[0], int(sLen))
    pos += int(sLen)
    return true
  elif T is seq:
    return mtMarshalSeq(buf, cap, value, pos)
  elif T is array:
    # Non-POD array (e.g. array[N, string]); iterate per element.
    for i in 0 ..< value.len:
      if not mtMarshalValue(buf, cap, value[i], pos):
        return false
    return true
  elif T is (object or tuple):
    for _, fval in fieldPairs(value):
      if not mtMarshalValue(buf, cap, fval, pos):
        return false
    return true
  elif T is distinct:
    # Unwrap to the underlying base and recurse. POD distincts (e.g.
    # `distinct int32`) are caught by the `supportsCopyMem` branch above;
    # this branch handles distincts whose base needs structural marshaling
    # such as `distinct seq[byte]` or `distinct string`.
    var base = distinctBase(value)
    return mtMarshalValue(buf, cap, base, pos)
  else:
    {.error: "mt broker payload field type is unsupported by mtMarshalValue: " & $T.}

proc mtUnmarshalValue*[T](
    buf: ptr UncheckedArray[byte], len: int, value: var T, pos: var int
): bool {.gcsafe.} =
  mixin mtUnmarshalValue # allow user overloads for field types
  when T is ref:
    when compiles(value.brokerCtx):
      # reduced-A: BrokerInterface ref — same-thread routing handle, see the
      # marshal counterpart. Reads the pointer bytes back. Bypasses GC refcount
      # (the instance stays pinned by its provider closures), valid only because
      # the create-instance path is same-thread and transient.
      if pos + sizeof(pointer) > len:
        return false
      copyMem(unsafeAddr value, addr buf[pos], sizeof(pointer))
      pos += sizeof(pointer)
      return true
    else:
      {.error: "mt broker payload field type is unsupported (ref T): " & $T.}
  # ptr / pointer / cstring fall through to the `supportsCopyMem` branch
  # below and are marshaled bytewise. Caller is responsible for the
  # lifetime of what they point to — typically used for shared structures
  # like chronos' ThreadSignalPtr.
  elif supportsCopyMem(T):
    if pos + sizeof(T) > len:
      return false
    copyMem(unsafeAddr value, addr buf[pos], sizeof(T))
    pos += sizeof(T)
    return true
  elif T is string:
    if pos + 4 > len:
      return false
    var sLen: uint32
    copyMem(addr sLen, addr buf[pos], 4)
    pos += 4
    if pos + int(sLen) > len:
      return false
    value = newString(int(sLen))
    if sLen > 0'u32:
      copyMem(addr value[0], addr buf[pos], int(sLen))
    pos += int(sLen)
    return true
  elif T is seq:
    return mtUnmarshalSeq(buf, len, value, pos)
  elif T is array:
    for i in 0 ..< value.len:
      if not mtUnmarshalValue(buf, len, value[i], pos):
        return false
    return true
  elif T is (object or tuple):
    for _, fval in fieldPairs(value):
      if not mtUnmarshalValue(buf, len, fval, pos):
        return false
    return true
  elif T is distinct:
    type Base = distinctBase(T)
    var base: Base
    if not mtUnmarshalValue(buf, len, base, pos):
      return false
    value = T(base)
    return true
  else:
    {.error: "mt broker payload field type is unsupported by mtUnmarshalValue: " & $T.}

# ---------------------------------------------------------------------------
# Marshal-size companion — pure byte-count walk, no writes.
#
# Mirrors mtMarshalValue exactly so the heap-spill path (flexible-mt-dispatch
# Part 2) can size an exact `allocShared0` buffer in one pass when a payload
# overflows the fixed slab cell. MUST stay structurally in lockstep with
# mtMarshalValue: every branch that advances `pos` there adds the same count
# here. Returns the marshaled byte length.
# ---------------------------------------------------------------------------

proc mtMarshalSizeValue*[T](value: T): int {.gcsafe.}

proc mtMarshalSizeSeq*[U](value: openArray[U]): int {.gcsafe.} =
  mixin mtMarshalSizeValue
  result = 4 # length prefix
  when supportsCopyMem(U):
    result += value.len * sizeof(U)
  else:
    for e in value:
      result += mtMarshalSizeValue(e)

proc mtMarshalSizeValue*[T](value: T): int {.gcsafe.} =
  mixin mtMarshalSizeValue
  when T is ref:
    when compiles(value.brokerCtx):
      return sizeof(pointer)
    else:
      {.error: "mt broker payload field type is unsupported (ref T): " & $T.}
  elif supportsCopyMem(T):
    return sizeof(T)
  elif T is string:
    return 4 + value.len
  elif T is seq:
    return mtMarshalSizeSeq(value)
  elif T is array:
    result = 0
    for i in 0 ..< value.len:
      result += mtMarshalSizeValue(value[i])
  elif T is (object or tuple):
    result = 0
    for _, fval in fieldPairs(value):
      result += mtMarshalSizeValue(fval)
  elif T is distinct:
    var base = distinctBase(value)
    return mtMarshalSizeValue(base)
  else:
    {.
      error: "mt broker payload field type is unsupported by mtMarshalSizeValue: " & $T
    .}

# ---------------------------------------------------------------------------
# Per-type wrapper proc generation (called from broker macros)
# ---------------------------------------------------------------------------

proc genMtCodecProcs*(
    marshalIdent, unmarshalIdent: NimNode, typeIdent: NimNode
): seq[NimNode] =
  ## Emits per-type marshal/unmarshal/size wrappers that bottom out to the
  ## generic primitives above. Three procs returned:
  ## [marshalProc, unmarshalProc, sizeProc]. The size proc is named
  ## `<marshalIdent>Size` and returns the exact marshaled byte length (used by
  ## the heap-spill path to size an allocShared0 buffer in one pass).
  let bufIdent = ident("buf")
  let capIdent = ident("cap")
  let lenIdent = ident("len")
  let valueIdent = ident("value")
  let dstIdent = ident("dst")
  let posIdent = ident("pos")
  let sizeIdent = ident($marshalIdent & "Size")

  let marshalProc = quote:
    proc `marshalIdent`(
        `bufIdent`: ptr UncheckedArray[byte], `capIdent`: int, `valueIdent`: `typeIdent`
    ): int {.gcsafe, raises: [].} =
      var `posIdent` = 0
      if mtMarshalValue(`bufIdent`, `capIdent`, `valueIdent`, `posIdent`):
        return `posIdent`
      return -1

  let unmarshalProc = quote:
    proc `unmarshalIdent`(
        `bufIdent`: ptr UncheckedArray[byte],
        `lenIdent`: int,
        `dstIdent`: var `typeIdent`,
    ): bool {.gcsafe, raises: [].} =
      var `posIdent` = 0
      return mtUnmarshalValue(`bufIdent`, `lenIdent`, `dstIdent`, `posIdent`)

  let sizeProc = quote:
    proc `sizeIdent`(`valueIdent`: `typeIdent`): int {.gcsafe, raises: [].} =
      mtMarshalSizeValue(`valueIdent`)

  @[marshalProc, unmarshalProc, sizeProc]
