{.used.}

import std/options
import results
import testutils/unittests
import waku/persistency/[types, keys, backend_sqlite]

template str(b: seq[byte]): string =
  var s = newString(b.len)
  for i, x in b:
    s[i] = char(x)
  s

proc payload(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s:
    result[i] = byte(c)

suite "Persistency SQLite backend":
  test "open in-memory backend and round-trip a single value":
    let b = openBackendInMemory().get()
    defer:
      b.close()

    b
      .applyOps(
        [
          TxOp(
            category: "msg",
            key: key("c1", 1'i64),
            kind: txPut,
            payload: payload("hello"),
          )
        ]
      )
      .get()

    let got = b.getOne("msg", key("c1", 1'i64)).get()
    check got.isSome
    check str(got.get) == "hello"

    check b.existsOne("msg", key("c1", 1'i64)).get()
    check not b.existsOne("msg", key("c1", 2'i64)).get()

  test "INSERT OR REPLACE overwrites payload for the same key":
    let b = openBackendInMemory().get()
    defer:
      b.close()
    let k = key("c1", 1'i64)
    b.applyOps([TxOp(category: "msg", key: k, kind: txPut, payload: payload("v1"))]).get()
    b.applyOps([TxOp(category: "msg", key: k, kind: txPut, payload: payload("v2"))]).get()
    check str(b.getOne("msg", k).get().get) == "v2"

  test "deleteOne reports whether the row existed":
    let b = openBackendInMemory().get()
    defer:
      b.close()
    let k = key("c1", 1'i64)
    check not b.deleteOne("msg", k).get()
    b.applyOps([TxOp(category: "msg", key: k, kind: txPut, payload: payload("x"))]).get()
    check b.deleteOne("msg", k).get()
    check not b.existsOne("msg", k).get()

  test "applyOps batches multiple ops atomically":
    let b = openBackendInMemory().get()
    defer:
      b.close()
    b
      .applyOps(
        [
          TxOp(
            category: "msg", key: key("c1", 1'i64), kind: txPut, payload: payload("a")
          ),
          TxOp(
            category: "msg", key: key("c1", 2'i64), kind: txPut, payload: payload("b")
          ),
          TxOp(
            category: "msg", key: key("c1", 3'i64), kind: txPut, payload: payload("c")
          ),
        ]
      )
      .get()
    check b.countRange("msg", prefixRange(key("c1"))).get() == 3

  test "scanRange ascending yields rows in key order":
    let b = openBackendInMemory().get()
    defer:
      b.close()
    let inserts = @[5'i64, 1, 4, 2, 3]
    var ops: seq[TxOp] = @[]
    for i in inserts:
      ops.add(
        TxOp(category: "msg", key: key("c1", i), kind: txPut, payload: payload($i))
      )
    b.applyOps(ops).get()

    let rows = b.scanRange("msg", prefixRange(key("c1"))).get()
    check rows.len == 5
    var seenOrder: seq[string]
    for r in rows:
      seenOrder.add(str(r.payload))
    check seenOrder == @["1", "2", "3", "4", "5"]

  test "scanRange descending yields rows in reverse key order":
    let b = openBackendInMemory().get()
    defer:
      b.close()
    for i in [1'i64, 2, 3]:
      b
        .applyOps(
          [TxOp(category: "msg", key: key("c1", i), kind: txPut, payload: payload($i))]
        )
        .get()
    let rows = b.scanRange("msg", prefixRange(key("c1")), reverse = true).get()
    check rows.len == 3
    check str(rows[0].payload) == "3"
    check str(rows[2].payload) == "1"

  test "scanRange respects half-open [start, stop) bounds":
    let b = openBackendInMemory().get()
    defer:
      b.close()
    for i in [1'i64, 2, 3, 4, 5]:
      b
        .applyOps(
          [TxOp(category: "msg", key: key("c1", i), kind: txPut, payload: payload($i))]
        )
        .get()
    let rng = KeyRange(start: key("c1", 2'i64), stop: key("c1", 4'i64))
    let rows = b.scanRange("msg", rng).get()
    check rows.len == 2 # 2 and 3, not 4
    check str(rows[0].payload) == "2"
    check str(rows[1].payload) == "3"

  test "scanRange with empty stop is open-ended":
    let b = openBackendInMemory().get()
    defer:
      b.close()
    for i in [1'i64, 2, 3]:
      b
        .applyOps(
          [TxOp(category: "msg", key: key("c1", i), kind: txPut, payload: payload($i))]
        )
        .get()
    let rng = KeyRange(start: key("c1", 2'i64), stop: rawKey(@[]))
    let rows = b.scanRange("msg", rng).get()
    check rows.len == 2
    check str(rows[1].payload) == "3"

  test "categories isolate keyspaces":
    let b = openBackendInMemory().get()
    defer:
      b.close()
    let k = key("c1", 1'i64)
    b
      .applyOps(
        [
          TxOp(category: "log", key: k, kind: txPut, payload: payload("log-1")),
          TxOp(
            category: "outgoing", key: k, kind: txPut, payload: payload("outgoing-1")
          ),
        ]
      )
      .get()
    check str(b.getOne("log", k).get().get) == "log-1"
    check str(b.getOne("outgoing", k).get().get) == "outgoing-1"
    check b.countRange("log", prefixRange(key("c1"))).get() == 1
    check b.countRange("outgoing", prefixRange(key("c1"))).get() == 1

  test "txDelete inside a batch removes the row":
    let b = openBackendInMemory().get()
    defer:
      b.close()
    let k = key("c1", 1'i64)
    b
      .applyOps(
        [
          TxOp(category: "msg", key: k, kind: txPut, payload: payload("v")),
          TxOp(category: "msg", key: k, kind: txDelete),
        ]
      )
      .get()
    check not b.existsOne("msg", k).get()

  test "missing key returns none":
    let b = openBackendInMemory().get()
    defer:
      b.close()
    check b.getOne("msg", key("nope")).get().isNone

  test "countRange of empty category is zero":
    let b = openBackendInMemory().get()
    defer:
      b.close()
    check b.countRange("msg", prefixRange(key("c1"))).get() == 0
