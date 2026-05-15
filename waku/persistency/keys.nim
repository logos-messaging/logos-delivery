## Composite-key encoding.
##
## Keys are byte-wise lexicographically comparable so SQLite's BLOB
## ordering reproduces tuple ordering of the original components. Each
## component contributes a self-delimiting, sort-stable byte sequence
## through an `encodePart` overload; the generic fallback recurses through
## `tuple | object` fields, so any user type whose fields are themselves
## encodable can be used as a key part without ceremony.
##
## ## Encoding by type
##
## | Nim type                | Bytes emitted                                                    |
## |-------------------------|------------------------------------------------------------------|
## | `string`, `openArray[byte]` | 2-byte BE length prefix + payload bytes (max 65535 bytes)     |
## | `int64`, `int`, ..      | XOR with 0x8000_0000_0000_0000 then 8-byte BE (sign-flip)         |
## | `uint64`, `uint32`, ..  | 8-byte BE                                                         |
## | `bool`                  | 1 byte (0/1)                                                      |
## | `byte`, `char`          | 1 byte                                                            |
## | `enum E`                | sign-flipped 8-byte BE of `ord(v).int64`                          |
## | `Key`                   | raw bytes (lets you embed a pre-built key inside another)         |
## | `tuple | object`        | each field encoded in declaration order, concatenated             |
##
## ## Sort-order caveats
##
## - Length-prefixed strings sort by **length first, then byte order**. For
##   uniform-length components (channel ids, hashes) this is identical to
##   natural lex order; for variable-length text it is not.
## - `int64.low < -1 < 0 < 1 < int64.high` after byte comparison thanks to
##   the sign flip.
## - Tuple/object ordering is component-major: field 0 dominates field 1
##   dominates field 2, like a multi-column ORDER BY.
##
## ## Building keys
##
## `key(...)` is a variadic macro that calls `encodePart` per argument. It
## accepts mixed types in one call:
##
## ```nim
## let k = key("channel-42", 1'i64)
## let k2 = key("channel-42", (epoch: 1'i64, seqNum: 7'u64))
## let k3 = key(myEnumValue, myObject)
## ```
##
## For a single value, `toKey(v)` is the simpler form (same semantics).

{.push raises: [].}

import std/macros
import ./types

const
  StringLenMax* = 0xFFFF
  SignFlip = 0x8000_0000_0000_0000'u64

# ── Low-level byte helpers ──────────────────────────────────────────────

proc appendBE16(buf: var seq[byte], v: uint16) =
  buf.add(byte((v shr 8) and 0xFF'u16))
  buf.add(byte(v and 0xFF'u16))

proc appendBE64(buf: var seq[byte], v: uint64) =
  for shift in countdown(56, 0, 8):
    buf.add(byte((v shr shift) and 0xFF'u64))

# ── encodePart: primitives ──────────────────────────────────────────────

proc encodePart*(dest: var seq[byte], s: string) =
  doAssert s.len <= StringLenMax, "string component exceeds 65535 bytes"
  appendBE16(dest, uint16(s.len))
  for c in s:
    dest.add(byte(c))

proc encodePart*(dest: var seq[byte], raw: openArray[byte]) =
  doAssert raw.len <= StringLenMax, "byte component exceeds 65535 bytes"
  appendBE16(dest, uint16(raw.len))
  for b in raw:
    dest.add(b)

proc encodePart*(dest: var seq[byte], i: int64) =
  appendBE64(dest, cast[uint64](i) xor SignFlip)

proc encodePart*(dest: var seq[byte], u: uint64) =
  appendBE64(dest, u)

proc encodePart*(dest: var seq[byte], i: int) {.inline.} =
  encodePart(dest, i.int64)

proc encodePart*(dest: var seq[byte], i: int32) {.inline.} =
  encodePart(dest, i.int64)

proc encodePart*(dest: var seq[byte], i: int16) {.inline.} =
  encodePart(dest, i.int64)

proc encodePart*(dest: var seq[byte], i: int8) {.inline.} =
  encodePart(dest, i.int64)

proc encodePart*(dest: var seq[byte], u: uint32) {.inline.} =
  encodePart(dest, u.uint64)

proc encodePart*(dest: var seq[byte], u: uint16) {.inline.} =
  encodePart(dest, u.uint64)

proc encodePart*(dest: var seq[byte], b: bool) =
  dest.add(if b: 1'u8 else: 0'u8)

proc encodePart*(dest: var seq[byte], b: byte) =
  dest.add(b)

proc encodePart*(dest: var seq[byte], c: char) =
  dest.add(byte(c))

proc encodePart*(dest: var seq[byte], k: Key) =
  ## Embed an already-encoded Key (e.g. a pre-built prefix) verbatim.
  for b in bytes(k):
    dest.add(b)

# ── encodePart: generic structural fallback ─────────────────────────────

proc encodePart*[E: enum](dest: var seq[byte], v: E) {.inline.} =
  encodePart(dest, int64(ord(v)))

proc encodePart*[T: tuple | object](dest: var seq[byte], v: T) =
  ## Walks the type's fields in declaration order. Each field must itself
  ## have an `encodePart` overload (primitive, Key, or another struct).
  for f in fields(v):
    encodePart(dest, f)

# ── Public Key constructors ─────────────────────────────────────────────

proc add*[T](k: var Key, v: T) =
  ## In-place key extension. Equivalent to writing `encodePart` against the
  ## underlying byte buffer.
  var buf = seq[byte](k)
  encodePart(buf, v)
  k = Key(buf)

proc toKey*[T](v: T): Key =
  ## Single-value Key constructor. Equivalent to `key(v)`.
  var buf: seq[byte] = @[]
  encodePart(buf, v)
  return Key(buf)

macro key*(parts: varargs[typed]): Key =
  ## Variadic Key builder. Accepts any mix of types for which `encodePart`
  ## resolves -- including tuples and objects via the structural fallback.
  ##
  ## ```nim
  ## key()                              # empty Key
  ## key("ch", 1'i64)                   # 2-component
  ## key("ch", (1'i64, 7'u64))          # nested tuple flattens
  ## ```
  let bufSym = genSym(nskVar, "keyBuf")
  var body = newStmtList()
  body.add quote do:
    var `bufSym`: seq[byte] = @[]
  for p in parts:
    body.add quote do:
      encodePart(`bufSym`, `p`)
  body.add quote do:
    Key(`bufSym`)
  return newBlockStmt(body)

# ── Range helpers ───────────────────────────────────────────────────────

proc prefixRange*(prefix: Key): KeyRange =
  ## Build [prefix, prefix++) — a half-open range that captures every key
  ## starting with `prefix`. If `prefix` is all 0xFF, the upper bound is
  ## empty (open-ended); the backend treats `stop.len == 0` as "no upper
  ## bound".
  var stop = bytes(prefix)
  var i = stop.len - 1
  while i >= 0:
    if stop[i] != 0xFF'u8:
      stop[i] = stop[i] + 1'u8
      stop.setLen(i + 1)
      return KeyRange(start: prefix, stop: Key(stop))
    dec i
  return KeyRange(start: prefix, stop: Key(@[]))

{.pop.}
