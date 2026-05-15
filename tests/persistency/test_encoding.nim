{.used.}

import std/[algorithm, options, os, times]
import chronos, results
import testutils/unittests
import waku/persistency/persistency

# Reusable byte-wise comparator (Key has its own `<`, but we sometimes
# want to sort `seq[Key]` here without relying on it for double-checking).
proc cmpBytes(a, b: Key): int =
  let ab = bytes(a)
  let bb = bytes(b)
  let n = min(ab.len, bb.len)
  for i in 0 ..< n:
    if ab[i] != bb[i]:
      return cmp(ab[i], bb[i])
  cmp(ab.len, bb.len)

template str(b: seq[byte]): string =
  var s = newString(b.len)
  for i, x in b:
    s[i] = char(x)
  s

# Shared payload types used by multiple tests.
type
  Mood = enum
    moodCalm
    moodHappy
    moodAngry

  Header = object
    sender: string
    epoch: int64

  Msg = object
    header: Header
    mood: Mood
    body: seq[byte]

suite "Persistency generic encoding":
  # ── Key macro: composite types ────────────────────────────────────────

  test "key macro accepts plain tuples":
    let k1 = key(("ch", 1'i64))
    let k2 = key("ch", 1'i64)
    # A plain tuple is encoded field-by-field, so the result is identical
    # to passing the fields directly.
    check k1 == k2

  test "key macro accepts named tuples":
    type Coord = tuple[lane: string, seqNum: int64]
    let k = key((lane: "a", seqNum: 7'i64))
    let kFlat = key("a", 7'i64)
    check k == kFlat

  test "key macro accepts a user object":
    let k1 = key(Header(sender: "alice", epoch: 5'i64))
    let k2 = key("alice", 5'i64)
    check k1 == k2

  test "key macro accepts nested object inside another arg":
    let k1 = key("v1", Header(sender: "alice", epoch: 5'i64))
    let k2 = key("v1", "alice", 5'i64)
    check k1 == k2

  test "key macro encodes enums":
    let k1 = key(moodAngry)
    let k2 = key(int64(ord(moodAngry)))
    check k1 == k2

  test "toKey is equivalent to single-arg key()":
    check toKey("x") == key("x")
    check toKey(42'i64) == key(42'i64)
    check toKey(Header(sender: "a", epoch: 1)) == key("a", 1'i64)

  test "tuple-encoded keys preserve field-major sort order":
    let inputs = @[
      key(("a", 0'i64)),
      key(("a", 1'i64)),
      key(("a", int64.high)),
      key(("b", int64.low)),
      key(("b", 0'i64)),
    ]
    var shuffled = @[inputs[3], inputs[0], inputs[4], inputs[2], inputs[1]]
    shuffled.sort(cmpBytes)
    check shuffled == inputs

  test "embedded Key encodes verbatim":
    let inner = key("a", 7'i64)
    let outer = key("prefix", inner)
    # Expanded: bytes of "prefix" + raw bytes of inner.
    let expanded = key("prefix", "a", 7'i64)
    check outer == expanded

  # ── Payload macro / toPayload ─────────────────────────────────────────

  test "toPayload encodes primitives":
    check str(toPayload("hi")).len == 4 # 2-byte len prefix + 2 chars
    check toPayload(42'i64).len == 8
    check toPayload(true) == @[1'u8]
    check toPayload(false) == @[0'u8]

  test "toPayload encodes objects field-by-field":
    let m = Msg(
      header: Header(sender: "alice", epoch: 9'i64),
      mood: moodHappy,
      body: @[0xAA'u8, 0xBB, 0xCC],
    )
    let p = toPayload(m)
    let pManual = payload("alice", 9'i64, int64(ord(moodHappy)), @[0xAA'u8, 0xBB, 0xCC])
    check p == pManual

  test "payload macro concatenates parts":
    let p = payload("v1", 1'i64, @[0xDE'u8, 0xAD])
    # Same as building each piece separately.
    var expected: seq[byte] = @[]
    encodePart(expected, "v1")
    encodePart(expected, 1'i64)
    encodePart(expected, @[0xDE'u8, 0xAD])
    check p == expected

  # ── End-to-end through the facade ─────────────────────────────────────

  asyncTest "persistEncoded round-trips a struct through SQLite":
    let root = getTempDir() / ("persistency_enc_" & $epochTime().int)
    removeDir(root)
    defer:
      removeDir(root)
    let p = Persistency.instance(root).get()
    defer:
      Persistency.reset()
    let job = p.openJob("t").get()

    let m = Msg(
      header: Header(sender: "alice", epoch: 1'i64),
      mood: moodHappy,
      body: @[1'u8, 2, 3],
    )
    let k = key("channel-42", m.header.epoch)
    await job.persistEncoded("msg", k, m)

    # Poll for the row, then read it back as raw bytes.
    let deadline = epochTime() + 1.0
    var got: Option[seq[byte]]
    while epochTime() < deadline:
      let r = await job.get("msg", k)
      check r.isOk
      got = r.get()
      if got.isSome:
        break
      await sleepAsync(chronos.milliseconds(2))
    check got.isSome
    check got.get == toPayload(m)
