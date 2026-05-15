{.used.}

import std/[algorithm, sequtils]
import testutils/unittests
import waku/persistency/[types, keys]

proc cmpBytes(a, b: Key): int =
  let ab = bytes(a)
  let bb = bytes(b)
  let n = min(ab.len, bb.len)
  for i in 0 ..< n:
    if ab[i] != bb[i]:
      return cmp(ab[i], bb[i])
  cmp(ab.len, bb.len)

suite "Persistency keys":
  test "string components sort by length, then byte order":
    var ks = @[key("ab"), key(""), key("a"), key("aa"), key("b")]
    ks.sort(cmpBytes)
    # length-prefix encoding => shorter strings always sort before longer
    # ones; same-length strings sort in byte order.
    check ks == @[key(""), key("a"), key("b"), key("aa"), key("ab")]

  test "same-length strings sort in byte order":
    var ks = @[key("delta"), key("alpha"), key("gamma"), key("bravo")]
    ks.sort(cmpBytes)
    check ks == @[key("alpha"), key("bravo"), key("delta"), key("gamma")]

  test "int64 sign-flip preserves order across negative/zero/positive":
    let inputs = @[
      key("c", int64.low),
      key("c", -2'i64),
      key("c", -1'i64),
      key("c", 0'i64),
      key("c", 1'i64),
      key("c", 2'i64),
      key("c", int64.high),
    ]
    var shuffled = inputs
    # rotate so the natural order is not the input order
    shuffled = @[
      shuffled[3],
      shuffled[6],
      shuffled[0],
      shuffled[5],
      shuffled[1],
      shuffled[4],
      shuffled[2],
    ]
    shuffled.sort(cmpBytes)
    check shuffled == inputs

  test "uint64 big-endian preserves order":
    let inputs = @[
      key("u", 0'u64),
      key("u", 1'u64),
      key("u", 256'u64),
      key("u", 1_000_000'u64),
      key("u", uint64.high - 1),
      key("u", uint64.high),
    ]
    var shuffled = @[inputs[3], inputs[0], inputs[5], inputs[2], inputs[1], inputs[4]]
    shuffled.sort(cmpBytes)
    check shuffled == inputs

  test "composite (string, string) tuple ordering":
    # First component "a" / "b" — both length 1, so byte order applies.
    # Second components grouped by first; within each group, again
    # length-then-byte: "" (len 0) < "a","z" (len 1) < "ab" (len 2).
    let inputs = @[
      key("a", ""),
      key("a", "a"),
      key("a", "z"),
      key("a", "ab"),
      key("b", ""),
      key("b", "a"),
    ]
    var shuffled = inputs.reversed()
    shuffled.sort(cmpBytes)
    check shuffled == inputs

  test "composite (string, int64) tuple ordering":
    let inputs = @[
      key("a", int64.low),
      key("a", -1'i64),
      key("a", 0'i64),
      key("a", 1'i64),
      key("b", int64.low),
      key("b", 0'i64),
    ]
    var shuffled = inputs.reversed()
    shuffled.sort(cmpBytes)
    check shuffled == inputs

  test "shorter composite key precedes longer one sharing its prefix":
    check key("a") < key("a", 0'i64)
    check key("a") < key("a", "")
    check key("a", "x") < key("a", "x", "y")

  test "Key equality is byte-wise":
    check key("a", 1'i64) == key("a", 1'i64)
    check not (key("a", 1'i64) == key("a", 2'i64))

  test "prefixRange.start equals prefix":
    let r = prefixRange(key("a"))
    check r.start == key("a")

  test "prefixRange.stop excludes the prefix and admits all extensions":
    let r = prefixRange(key("a"))
    let extensions = @[
      key("a"),
      key("a", 0'i64),
      key("a", int64.high),
      key("a", "x"),
      key("a", uint64.high),
    ]
    for k in extensions:
      check r.start <= k
      check k < r.stop

  test "prefixRange.stop excludes siblings outside the prefix":
    let r = prefixRange(key("a"))
    # "b" has the same encoded length as "a" but a higher last byte, so it
    # should be at-or-above the exclusive stop.
    check not (key("b") < r.stop)
    # "ab" has more bytes — its 2-byte length prefix bumps it past stop.
    check not (key("ab") < r.stop)
    # The empty key sits before the start.
    check key("") < r.start

  test "prefixRange handles all-0xFF prefix as open-ended":
    let prefix = rawKey(@[0xFF'u8, 0xFF, 0xFF])
    let r = prefixRange(prefix)
    check r.start == prefix
    check bytes(r.stop).len == 0
