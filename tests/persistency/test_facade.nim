{.used.}

import std/[options, os, strutils, times]
import chronos, results
import testutils/unittests
import waku/persistency/persistency

proc payload(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s:
    result[i] = byte(c)

template str(b: seq[byte]): string =
  var s = newString(b.len)
  for i, x in b:
    s[i] = char(x)
  s

proc tmpRoot(label: string): string =
  let p = getTempDir() / ("persistency_facade_" & label & "_" & $epochTime().int)
  removeDir(p)
  p

# Bounded poll on exists() to bridge the documented persist->read race.
proc waitUntilExists(t: Job, category: string, k: Key, timeoutMs = 1000): bool =
  let deadline = epochTime() + (timeoutMs.float / 1000.0)
  while epochTime() < deadline:
    let r = waitFor t.exists(category, k)
    if r.isOk and r.get():
      return true
    sleep(2)
  false

procSuite "Persistency facade":

  test "persistPut then get round-trips":
    let root = tmpRoot("put_get")
    defer: removeDir(root)
    let p = Persistency.instance(root).get()
    defer: Persistency.reset()
    let t = p.openJob("t").get()

    let k = key("c", 1'i64)
    t.persistPut("msg", k, payload("hi"))
    check t.waitUntilExists("msg", k)

    let got = (waitFor t.get("msg", k)).get()
    check got.isSome
    check str(got.get) == "hi"

  test "persist (batch) is atomic and visible together":
    let root = tmpRoot("batch")
    defer: removeDir(root)
    let p = Persistency.instance(root).get()
    defer: Persistency.reset()
    let t = p.openJob("t").get()

    var ops: seq[TxOp]
    for i in 1'i64 .. 4:
      ops.add(TxOp(
        category: "msg", key: key("c", i), kind: txPut, payload: payload($i)
      ))
    t.persist(ops)
    check t.waitUntilExists("msg", key("c", 4'i64))

    let cnt = (waitFor t.count("msg", prefixRange(key("c")))).get()
    check cnt == 4

  test "scanPrefix returns rows in key order":
    let root = tmpRoot("scan")
    defer: removeDir(root)
    let p = Persistency.instance(root).get()
    defer: Persistency.reset()
    let t = p.openJob("t").get()

    for i in [3'i64, 1, 4, 1, 5, 9, 2]:
      t.persistPut("msg", key("c", i), payload($i))
    check t.waitUntilExists("msg", key("c", 9'i64))

    let rows = (waitFor t.scanPrefix("msg", key("c"))).get()
    # 7 ops with duplicate key i=1 -> 6 distinct rows
    check rows.len == 6

    var seenOrder: seq[int]
    for r in rows:
      seenOrder.add(parseInt(str(r.payload)))
    check seenOrder == @[1, 2, 3, 4, 5, 9]

  test "scanPrefix reverse=true returns rows in reverse order":
    let root = tmpRoot("scan_rev")
    defer: removeDir(root)
    let p = Persistency.instance(root).get()
    defer: Persistency.reset()
    let t = p.openJob("t").get()

    for i in 1'i64 .. 3:
      t.persistPut("msg", key("c", i), payload($i))
    check t.waitUntilExists("msg", key("c", 3'i64))

    let rows = (waitFor t.scanPrefix("msg", key("c"), reverse = true)).get()
    check rows.len == 3
    check str(rows[0].payload) == "3"
    check str(rows[2].payload) == "1"

  test "deleteAcked round-trips and reports row presence":
    let root = tmpRoot("delete")
    defer: removeDir(root)
    let p = Persistency.instance(root).get()
    defer: Persistency.reset()
    let t = p.openJob("t").get()

    let k = key("c", 1'i64)
    let miss = (waitFor t.deleteAcked("msg", k)).get()
    check miss == false

    t.persistPut("msg", k, payload("v"))
    check t.waitUntilExists("msg", k)

    let hit = (waitFor t.deleteAcked("msg", k)).get()
    check hit == true
    check (waitFor t.exists("msg", k)).get() == false

  test "persistDelete fire-and-forget removes the row":
    let root = tmpRoot("fadel")
    defer: removeDir(root)
    let p = Persistency.instance(root).get()
    defer: Persistency.reset()
    let t = p.openJob("t").get()

    let k = key("c", 1'i64)
    t.persistPut("msg", k, payload("v"))
    check t.waitUntilExists("msg", k)
    t.persistDelete("msg", k)
    # Poll for absence.
    let deadline = epochTime() + 1.0
    var gone = false
    while epochTime() < deadline:
      if not (waitFor t.exists("msg", k)).get():
        gone = true
        break
      sleep(2)
    check gone

  test "two jobs do not see each other's data via the facade":
    let root = tmpRoot("iso")
    defer: removeDir(root)
    let p = Persistency.instance(root).get()
    defer: Persistency.reset()
    let a = p.openJob("a").get()
    let b = p.openJob("b").get()

    let k = key("c", 1'i64)
    a.persistPut("msg", k, payload("A"))
    b.persistPut("msg", k, payload("B"))
    check a.waitUntilExists("msg", k)
    check b.waitUntilExists("msg", k)

    check str((waitFor a.get("msg", k)).get().get) == "A"
    check str((waitFor b.get("msg", k)).get().get) == "B"
    check (waitFor a.count("msg", prefixRange(key("c")))).get() == 1
    check (waitFor b.count("msg", prefixRange(key("c")))).get() == 1
