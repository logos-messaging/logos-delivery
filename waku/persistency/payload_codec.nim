## Generic length-prefixed blob codec for persistency payloads.
##
## Symmetric counterpart to `keys.nim`'s `encodePart`: every persisted value
## round-trips through `writePart`/`readPart` over a `ReadCtx` cursor. Unlike
## keys, payloads are not byte-wise sort-stable, so strings and byte blobs use
## a **4-byte BE length prefix** (4 GiB ceiling) instead of keys.nim's 2-byte
## (64 KiB) prefix — the cap that originally forced SDS to hand-roll its codec.
##
## ## How a type opts in
##
## Primitives, `string`, `seq[byte]`, `enum`, `distinct`, `Time`, `seq[T]`,
## `HashSet[T]` and tuples already have codecs here. A **named struct** opts in
## with a single line:
##
## ```nim
## BlobCodec(MyType)
## ```
##
## which emits both `writePart`/`readPart` for `MyType` from its fields, in
## declaration order, and reconstructs the value via `MyType.init(...)`
## (positional). This is the *only* mechanism for structs — there is
## deliberately no `fieldPairs`/default-construct path, so `{.requiresInit.}`
## types (which cannot be zero-initialised) work unchanged. The contract:
##
##  * the type is a value object whose `init` takes its fields positionally in
##    declaration order;
##  * only public fields participate (private fields are invisible to the
##    macro and would be dropped — don't persist such types);
##  * `BlobCodec` must be called for a field's type *before* the struct
##    that contains it (Nim resolves the concrete `writePart`/`readPart`
##    top-down).
##
## ## Entry points
##
## `toBlob(v)` → `seq[byte]`, `fromBlob(bytes, T)` → `T` (raises `ValueError`
## on truncated/corrupt input).

{.push raises: [].}

import std/[macros, sets, times, typetraits]

type ReadCtx* = object
  buf*: seq[byte]
  pos*: int

proc initReadCtx*(bytes: openArray[byte]): ReadCtx =
  ReadCtx(buf: @bytes, pos: 0)

proc need(r: ReadCtx, n: int) {.raises: [ValueError].} =
  if n < 0 or r.pos + n > r.buf.len:
    raise newException(ValueError, "truncated payload: need " & $n & " more bytes")

# ── Fixed-width integers ────────────────────────────────────────────────

proc writePart*(buf: var seq[byte], v: uint32) =
  buf.add(byte((v shr 24) and 0xFF'u32))
  buf.add(byte((v shr 16) and 0xFF'u32))
  buf.add(byte((v shr 8) and 0xFF'u32))
  buf.add(byte(v and 0xFF'u32))

proc readPart*(r: var ReadCtx, _: typedesc[uint32]): uint32 {.raises: [ValueError].} =
  r.need(4)
  result =
    (uint32(r.buf[r.pos]) shl 24) or (uint32(r.buf[r.pos + 1]) shl 16) or
    (uint32(r.buf[r.pos + 2]) shl 8) or uint32(r.buf[r.pos + 3])
  r.pos += 4

proc writePart*(buf: var seq[byte], v: int64) =
  let u = cast[uint64](v)
  for shift in countdown(56, 0, 8):
    buf.add(byte((u shr shift) and 0xFF'u64))

proc readPart*(r: var ReadCtx, _: typedesc[int64]): int64 {.raises: [ValueError].} =
  r.need(8)
  var u: uint64 = 0
  for i in 0 ..< 8:
    u = (u shl 8) or uint64(r.buf[r.pos + i])
  r.pos += 8
  cast[int64](u)

proc writePart*(buf: var seq[byte], v: int) =
  writePart(buf, int64(v))

proc readPart*(r: var ReadCtx, _: typedesc[int]): int {.raises: [ValueError].} =
  int(readPart(r, int64))

# ── Small scalars ───────────────────────────────────────────────────────

proc writePart*(buf: var seq[byte], v: bool) =
  buf.add(if v: 1'u8 else: 0'u8)

proc readPart*(r: var ReadCtx, _: typedesc[bool]): bool {.raises: [ValueError].} =
  r.need(1)
  result = r.buf[r.pos] != 0'u8
  r.pos += 1

proc writePart*(buf: var seq[byte], v: byte) =
  buf.add(v)

proc readPart*(r: var ReadCtx, _: typedesc[byte]): byte {.raises: [ValueError].} =
  r.need(1)
  result = r.buf[r.pos]
  r.pos += 1

proc writePart*(buf: var seq[byte], v: char) =
  buf.add(byte(v))

proc readPart*(r: var ReadCtx, _: typedesc[char]): char {.raises: [ValueError].} =
  r.need(1)
  result = char(r.buf[r.pos])
  r.pos += 1

proc writePart*[E: enum](buf: var seq[byte], v: E) =
  writePart(buf, int64(ord(v)))

proc readPart*[E: enum](r: var ReadCtx, _: typedesc[E]): E {.raises: [ValueError].} =
  E(readPart(r, int64))

# ── string / seq[byte] (4-byte length) ──────────────────────────────────

proc writePart*(buf: var seq[byte], s: string) =
  writePart(buf, uint32(s.len))
  for c in s:
    buf.add(byte(c))

proc readPart*(r: var ReadCtx, _: typedesc[string]): string {.raises: [ValueError].} =
  let n = int(readPart(r, uint32))
  r.need(n)
  result = newString(n)
  for i in 0 ..< n:
    result[i] = char(r.buf[r.pos + i])
  r.pos += n

proc writePart*(buf: var seq[byte], b: seq[byte]) =
  writePart(buf, uint32(b.len))
  for x in b:
    buf.add(x)

proc readPart*(r: var ReadCtx, _: typedesc[seq[byte]]): seq[byte] {.raises: [ValueError].} =
  let n = int(readPart(r, uint32))
  r.need(n)
  result = newSeq[byte](n)
  for i in 0 ..< n:
    result[i] = r.buf[r.pos + i]
  r.pos += n

# ── distinct (e.g. SdsParticipantID = distinct string) ──────────────────

proc writePart*[T: distinct](buf: var seq[byte], v: T) =
  mixin writePart
  writePart(buf, distinctBase(T)(v))

proc readPart*[T: distinct](
    r: var ReadCtx, _: typedesc[T]
): T {.raises: [ValueError].} =
  mixin readPart
  T(readPart(r, distinctBase(T)))

# ── Time ────────────────────────────────────────────────────────────────

proc writePart*(buf: var seq[byte], t: Time) =
  writePart(buf, t.toUnix())
  writePart(buf, uint32(t.nanosecond))

proc readPart*(r: var ReadCtx, _: typedesc[Time]): Time {.raises: [ValueError].} =
  let secs = readPart(r, int64)
  let nanos = int(readPart(r, uint32))
  if nanos < 0 or nanos > 999_999_999:
    raise newException(ValueError, "nanosecond out of range: " & $nanos)
  initTime(secs, nanos)

# ── Containers ──────────────────────────────────────────────────────────

proc writePart*[T](buf: var seq[byte], xs: seq[T]) =
  mixin writePart
  writePart(buf, uint32(xs.len))
  for x in xs:
    writePart(buf, x)

proc readPart*[T](
    r: var ReadCtx, _: typedesc[seq[T]]
): seq[T] {.raises: [ValueError].} =
  mixin readPart
  let n = int(readPart(r, uint32))
  result = newSeqOfCap[T](n)
  for _ in 0 ..< n:
    result.add(readPart(r, T))

proc writePart*[T](buf: var seq[byte], s: HashSet[T]) =
  mixin writePart
  writePart(buf, uint32(s.len))
  for x in s:
    writePart(buf, x)

proc readPart*[T](
    r: var ReadCtx, _: typedesc[HashSet[T]]
): HashSet[T] {.raises: [ValueError].} =
  mixin readPart
  let n = int(readPart(r, uint32))
  result = initHashSet[T](max(n, 2))
  for _ in 0 ..< n:
    result.incl(readPart(r, T))

proc writePart*[T: tuple](buf: var seq[byte], v: T) =
  mixin writePart
  for f in fields(v):
    writePart(buf, f)

proc readPart*[T: tuple](
    r: var ReadCtx, _: typedesc[T]
): T {.raises: [ValueError].} =
  mixin readPart
  for f in fields(result):
    f = readPart(r, typeof(f))

# ── Named-struct derivation ─────────────────────────────────────────────

proc objectRecList(tSym: NimNode): NimNode {.compileTime.} =
  ## Resolve a type symbol to its object's RecList, preserving field types
  ## exactly as written (getImpl, not getTypeImpl, so `HashSet[SdsMessageID]`
  ## and friends stay named rather than being expanded to their structure).
  var body = tSym.getImpl[2]
  while body.kind in {nnkRefTy, nnkPtrTy, nnkDistinctTy}:
    body = body[0]
  doAssert body.kind == nnkObjectTy,
    "BlobCodec: expected an object type, got " & treeRepr(body)
  body[2]

macro BlobCodec*(T: typedesc): untyped =
  ## Emit `writePart`/`readPart` for a named value object `T`, encoding each
  ## public field in declaration order and rebuilding via `T.init(...)`.
  let tSym = getTypeInst(T)[1]
  let recList = objectRecList(tSym)

  var fieldNames: seq[NimNode]
  var fieldTypes: seq[NimNode]
  for defs in recList:
    if defs.kind != nnkIdentDefs:
      continue
    # Rebuild the field type from its textual form rather than splicing the
    # resolved symbol: a spliced *alias* type symbol (e.g. `SdsMessageID =
    # string`) is mis-resolved as a value in `readPart(r, T)`, breaking
    # typedesc overload resolution. A fresh ident/expr behaves like literal
    # source and resolves to a typedesc correctly.
    let ftype = parseExpr(repr(defs[^2]))
    for i in 0 ..< defs.len - 2:
      var nameNode = defs[i]
      if nameNode.kind == nnkPragmaExpr:
        nameNode = nameNode[0]
      if nameNode.kind == nnkPostfix:
        nameNode = nameNode[1]
      fieldNames.add(ident($nameNode))
      fieldTypes.add(ftype.copyNimTree)

  let bufId = ident "buf"
  let vId = ident "v"
  let rId = ident "r"

  # writePart(buf: var seq[byte], v: T)
  var writeBody = newStmtList()
  for fn in fieldNames:
    writeBody.add(newCall(ident "writePart", bufId, newDotExpr(vId, fn)))
  let writeProc = newProc(
    name = ident "writePart",
    params = [
      newEmptyNode(),
      newIdentDefs(bufId, nnkVarTy.newTree(nnkBracketExpr.newTree(ident "seq", ident "byte"))),
      newIdentDefs(vId, tSym),
    ],
    body = writeBody,
  )

  # readPart(r: var ReadCtx, _: typedesc[T]): T {.raises: [ValueError].}
  var readBody = newStmtList()
  var tmps: seq[NimNode]
  for i, ft in fieldTypes:
    let tmp = genSym(nskLet, "f" & $i)
    tmps.add(tmp)
    readBody.add(newLetStmt(tmp, newCall(ident "readPart", rId, ft)))
  readBody.add(newCall(newDotExpr(tSym, ident "init"), tmps))
  let readProc = newProc(
    name = ident "readPart",
    params = [
      tSym,
      newIdentDefs(rId, nnkVarTy.newTree(ident "ReadCtx")),
      newIdentDefs(ident "_", nnkBracketExpr.newTree(ident "typedesc", tSym)),
    ],
    body = readBody,
  )
  readProc.addPragma(nnkExprColonExpr.newTree(
    ident "raises", nnkBracket.newTree(ident "ValueError")
  ))

  result = newStmtList(writeProc, readProc)

# ── Public entry points ─────────────────────────────────────────────────

proc toBlob*[T](v: T): seq[byte] =
  mixin writePart
  result = @[]
  writePart(result, v)

proc fromBlob*[T](bytes: openArray[byte], _: typedesc[T]): T {.raises: [ValueError].} =
  mixin readPart
  var r = initReadCtx(bytes)
  readPart(r, T)

{.pop.}
