## Core types for the logos-delivery persistency library.
##
## The library is backend-neutral CRUD: jobs own their domain ports and
## map them onto the primitives exposed in persistency.nim. See
## persistency.nim for the public facade and brokers.nim for the
## cross-thread plumbing.

{.push raises: [].}

type
  Key* = distinct seq[byte]

  KeyRange* = object
    start*: Key
    stop*: Key ## exclusive; an empty `stop` means "no upper bound"

  KvRow* = tuple[key: Key, payload: seq[byte]]

  TxOpKind* = enum
    txPut
    txDelete

  TxOp* = object
    category*: string
    key*: Key
    case kind*: TxOpKind
    of txPut:
      payload*: seq[byte]
    of txDelete:
      discard

  PersistencyErrorKind* = enum
    peBackend
    peClosed
    peInvalidArgument
    peTimeout
    peJobNotFound

  PersistencyError* = object
    kind*: PersistencyErrorKind
    msg*: string
    backendCode*: int

proc bytes*(k: Key): lent seq[byte] {.inline.} =
  seq[byte](k)

proc len*(k: Key): int {.inline.} =
  seq[byte](k).len

proc `==`*(a, b: Key): bool {.inline.} =
  seq[byte](a) == seq[byte](b)

proc `<`*(a, b: Key): bool =
  let ab = seq[byte](a)
  let bb = seq[byte](b)
  let n = min(ab.len, bb.len)
  for i in 0 ..< n:
    if ab[i] != bb[i]:
      return ab[i] < bb[i]
  return ab.len < bb.len

proc `<=`*(a, b: Key): bool {.inline.} =
  a == b or a < b

proc rawKey*(b: openArray[byte]): Key =
  var s = newSeq[byte](b.len)
  for i, v in b:
    s[i] = v
  return Key(s)

proc rawKey*(b: sink seq[byte]): Key {.inline.} =
  Key(b)

proc persistencyErr*(
    kind: PersistencyErrorKind, msg: string, backendCode = 0
): PersistencyError {.inline.} =
  PersistencyError(kind: kind, msg: msg, backendCode: backendCode)

proc `$`*(e: PersistencyError): string =
  "PersistencyError(" & $e.kind & ": " & e.msg &
    (if e.backendCode != 0: ", code=" & $e.backendCode else: "") & ")"
