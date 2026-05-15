## Generic payload encoding.
##
## Symmetric with `keys.nim`: reuses the same `encodePart` family so any
## Nim type composable from primitives + tuples/objects can be turned
## into a `seq[byte]` for storage. Unlike keys, payloads do **not** need
## byte-wise lex order — but using the same encoder keeps the system
## small. If a tenant needs a different on-disk format (CBOR, protobuf,
## SSZ, ...) they can write their own `toPayload` overload or pass an
## already-encoded `seq[byte]` to `persistPut`.
##
## ```nim
## # Primitives:
## let p1 = payload("hello")          # length-prefixed string bytes
## let p2 = payload(42'i64)           # 8 bytes, sign-flipped BE
##
## # Composites:
## type Msg = object
##   sender: string
##   epoch: int64
##   body: seq[byte]
## let p3 = toPayload(Msg(sender: "alice", epoch: 7, body: @[1'u8, 2, 3]))
##
## # Variadic when you want multiple values back-to-back:
## let p4 = payload("v1", 1'i64, body)
## ```

{.push raises: [].}

import std/macros
import ./keys

export keys.encodePart

proc toPayload*[T](v: T): seq[byte] =
  ## Single-value payload constructor. Equivalent to `payload(v)`.
  var buf: seq[byte] = @[]
  encodePart(buf, v)
  return buf

macro payload*(parts: varargs[typed]): seq[byte] =
  ## Variadic payload builder. Same encoder as `key(...)`; only the return
  ## type differs.
  let bufSym = genSym(nskVar, "payloadBuf")
  var body = newStmtList()
  body.add quote do:
    var `bufSym`: seq[byte] = @[]
  for p in parts:
    body.add quote do:
      encodePart(`bufSym`, `p`)
  body.add bufSym
  return newBlockStmt(body)

{.pop.}
