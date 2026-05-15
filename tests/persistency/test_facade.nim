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
proc waitUntilExists(
    t: Job, category: string, k: Key, timeoutMs = 1000
): Future[bool] {.async.} =
  let deadline = epochTime() + (timeoutMs.float / 1000.0)
  while epochTime() < deadline:
    let r = await t.exists(category, k)
    if r.isOk and r.get():
      return true
    await sleepAsync(chronos.milliseconds(2))
  return false

suite "Persistency facade":
  asyncTest "persistPut then get round-trips":
    let root = tmpRoot("put_get")
    defer:
      removeDir(root)
    let p = Persistency.instance(root).get()
    defer:
      Persistency.reset()
    let t = p.openJob("t").get()

    let k = key("c", 1'i64)
    await t.persistPut("msg", k, payload("hi"))
    let ckOk1 = await t.waitUntilExists("msg", k)
    check ckOk1

    let aw1 = await t.get("msg", k)
    let got = aw1.get()
    check got.isSome
    check str(got.get) == "hi"

  asyncTest "persist (batch) is atomic and visible together":
    let root = tmpRoot("batch")
    defer:
      removeDir(root)
    let p = Persistency.instance(root).get()
    defer:
      Persistency.reset()
    let t = p.openJob("t").get()

    var ops: seq[TxOp]
    for i in 1'i64 .. 4:
      ops.add(
        TxOp(category: "msg", key: key("c", i), kind: txPut, payload: payload($i))
      )
    await t.persist(ops)
    let ckOk2 = await t.waitUntilExists("msg", key("c", 4'i64))
    check ckOk2

    let aw2 = await t.count("msg", prefixRange(key("c")))
    let cnt = aw2.get()
    check cnt == 4

  asyncTest "scanPrefix returns rows in key order":
    let root = tmpRoot("scan")
    defer:
      removeDir(root)
    let p = Persistency.instance(root).get()
    defer:
      Persistency.reset()
    let t = p.openJob("t").get()

    for i in [3'i64, 1, 4, 1, 5, 9, 2]:
      await t.persistPut("msg", key("c", i), payload($i))
    let ckOk3 = await t.waitUntilExists("msg", key("c", 9'i64))
    check ckOk3

    let aw3 = await t.scanPrefix("msg", key("c"))
    let rows = aw3.get()
    # 7 ops with duplicate key i=1 -> 6 distinct rows
    check rows.len == 6

    var seenOrder: seq[int]
    for r in rows:
      seenOrder.add(parseInt(str(r.payload)))
    check seenOrder == @[1, 2, 3, 4, 5, 9]

  asyncTest "scanPrefix reverse=true returns rows in reverse order":
    let root = tmpRoot("scan_rev")
    defer:
      removeDir(root)
    let p = Persistency.instance(root).get()
    defer:
      Persistency.reset()
    let t = p.openJob("t").get()

    for i in 1'i64 .. 3:
      await t.persistPut("msg", key("c", i), payload($i))
    let ckOk4 = await t.waitUntilExists("msg", key("c", 3'i64))
    check ckOk4

    let aw4 = await t.scanPrefix("msg", key("c"), reverse = true)
    let rows = aw4.get()
    check rows.len == 3
    check str(rows[0].payload) == "3"
    check str(rows[2].payload) == "1"

  asyncTest "deleteAcked round-trips and reports row presence":
    let root = tmpRoot("delete")
    defer:
      removeDir(root)
    let p = Persistency.instance(root).get()
    defer:
      Persistency.reset()
    let t = p.openJob("t").get()

    let k = key("c", 1'i64)
    let aw5 = await t.deleteAcked("msg", k)
    let miss = aw5.get()
    check miss == false

    await t.persistPut("msg", k, payload("v"))
    let ckOk5 = await t.waitUntilExists("msg", k)
    check ckOk5

    let aw6 = await t.deleteAcked("msg", k)
    let hit = aw6.get()
    check hit == true
    let aw7 = await t.exists("msg", k)
    check aw7.get() == false

  asyncTest "persistDelete fire-and-forget removes the row":
    let root = tmpRoot("fadel")
    defer:
      removeDir(root)
    let p = Persistency.instance(root).get()
    defer:
      Persistency.reset()
    let t = p.openJob("t").get()

    let k = key("c", 1'i64)
    await t.persistPut("msg", k, payload("v"))
    let ckOk6 = await t.waitUntilExists("msg", k)
    check ckOk6
    await t.persistDelete("msg", k)
    # Poll for absence.
    let deadline = epochTime() + 1.0
    var gone = false
    while epochTime() < deadline:
      let aw8 = await t.exists("msg", k)
      if not aw8.get():
        gone = true
        break
      await sleepAsync(chronos.milliseconds(2))
    check gone

  asyncTest "two jobs do not see each other's data via the facade":
    let root = tmpRoot("iso")
    defer:
      removeDir(root)
    let p = Persistency.instance(root).get()
    defer:
      Persistency.reset()
    let a = p.openJob("a").get()
    let b = p.openJob("b").get()

    let k = key("c", 1'i64)
    await a.persistPut("msg", k, payload("A"))
    await b.persistPut("msg", k, payload("B"))
    let ckOk7 = await a.waitUntilExists("msg", k)
    check ckOk7
    let ckOk8 = await b.waitUntilExists("msg", k)
    check ckOk8

    let aw9 = await a.get("msg", k)
    check str(aw9.get().get) == "A"
    let aw10 = await b.get("msg", k)
    check str(aw10.get().get) == "B"
    let aw11 = await a.count("msg", prefixRange(key("c")))
    check aw11.get() == 1
    let aw12 = await b.count("msg", prefixRange(key("c")))
    check aw12.get() == 1
