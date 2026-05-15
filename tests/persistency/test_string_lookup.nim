{.used.}

import std/[options, os, times]
import chronos, results
import testutils/unittests
import waku/persistency/persistency

proc payloadBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s:
    result[i] = byte(c)

template str(b: seq[byte]): string =
  var s = newString(b.len)
  for i, x in b:
    s[i] = char(x)
  s

proc tmpRoot(label: string): string =
  let p = getTempDir() / ("persistency_lookup_" & label & "_" & $epochTime().int)
  removeDir(p)
  p

# Bridge the persist->read race (writes are fire-and-forget in v1).
proc waitUntilExists(
    p: Persistency, jobId, category: string, k: Key, timeoutMs = 1000
): Future[bool] {.async.} =
  let deadline = epochTime() + (timeoutMs.float / 1000.0)
  while epochTime() < deadline:
    let r = await p.exists(jobId, category, k)
    if r.isOk and r.get():
      return true
    await sleepAsync(chronos.milliseconds(2))
  return false

suite "Persistency string-id lookup":
  test "job(p, id) returns peJobNotFound when not open":
    let root = tmpRoot("notfound")
    defer:
      removeDir(root)
    let p = Persistency.instance(root).get()
    defer:
      Persistency.reset()

    let r = p.job("nope")
    check r.isErr
    check r.error.kind == peJobNotFound

  test "job(p, id) returns the Job after openJob":
    let root = tmpRoot("found")
    defer:
      removeDir(root)
    let p = Persistency.instance(root).get()
    defer:
      Persistency.reset()

    let opened = p.openJob("alpha").get()
    let looked = p.job("alpha").get()
    check looked.id == "alpha"
    check looked == opened # same ref, no need to peek at .context

  test "hasJob mirrors p.job()":
    let root = tmpRoot("has")
    defer:
      removeDir(root)
    let p = Persistency.instance(root).get()
    defer:
      Persistency.reset()

    check not p.hasJob("x")
    discard p.openJob("x")
    check p.hasJob("x")
    p.closeJob("x")
    check not p.hasJob("x")

  test "subscript [] returns the open Job":
    let root = tmpRoot("subscript")
    defer:
      removeDir(root)
    let p = Persistency.instance(root).get()
    defer:
      Persistency.reset()
    discard p.openJob("a").get()
    let j = p["a"]
    check j.id == "a"

  asyncTest "string-lookup persistPut + get round-trips without a Job ref":
    let root = tmpRoot("rw")
    defer:
      removeDir(root)
    let p = Persistency.instance(root).get()
    defer:
      Persistency.reset()
    discard p.openJob("svc").get()

    let k = key("c", 1'i64)
    await p.persistPut("svc", "msg", k, payloadBytes("hello"))
    let ckOk1 = await p.waitUntilExists("svc", "msg", k)
    check ckOk1

    let aw1 = await p.get("svc", "msg", k)
    let got = aw1.get()
    check got.isSome
    check str(got.get) == "hello"

  asyncTest "string-lookup reads short-circuit with peJobNotFound":
    let root = tmpRoot("missingread")
    defer:
      removeDir(root)
    let p = Persistency.instance(root).get()
    defer:
      Persistency.reset()

    let g = await p.get("nope", "msg", key("k"))
    check g.isErr
    check g.error.kind == peJobNotFound

    let c = await p.count("nope", "msg", prefixRange(key("k")))
    check c.isErr
    check c.error.kind == peJobNotFound

    let d = await p.deleteAcked("nope", "msg", key("k"))
    check d.isErr
    check d.error.kind == peJobNotFound

  asyncTest "string-lookup writes to an unknown job are dropped, not raised":
    let root = tmpRoot("missingwrite")
    defer:
      removeDir(root)
    let p = Persistency.instance(root).get()
    defer:
      Persistency.reset()

    # Should not raise and should not leak any state.
    await p.persistPut("ghost", "msg", key("k"), payloadBytes("v"))
    await p.persistDelete("ghost", "msg", key("k"))
    await p.persistEncoded("ghost", "msg", key("k"), 42'i64)
    check not p.hasJob("ghost")

  asyncTest "string-lookup persistEncoded round-trips a struct":
    let root = tmpRoot("encoded")
    defer:
      removeDir(root)
    type Item = object
      tag: string
      n: int64

    let p = Persistency.instance(root).get()
    defer:
      Persistency.reset()
    discard p.openJob("e").get()

    let k = key("items", 1'i64)
    await p.persistEncoded("e", "msg", k, Item(tag: "alpha", n: 7))
    let ckOk2 = await p.waitUntilExists("e", "msg", k)
    check ckOk2

    let aw2 = await p.get("e", "msg", k)
    let got = aw2.get()
    check got.isSome
    check got.get == toPayload(Item(tag: "alpha", n: 7))

  asyncTest "string-lookup scan returns the same rows as Job-form":
    let root = tmpRoot("scan")
    defer:
      removeDir(root)
    let p = Persistency.instance(root).get()
    defer:
      Persistency.reset()
    let j = p.openJob("s").get()

    for i in 1'i64 .. 3:
      await p.persistPut("s", "msg", key("c", i), payloadBytes($i))
    let ckOk3 = await p.waitUntilExists("s", "msg", key("c", 3'i64))
    check ckOk3

    let aw3 = await p.scanPrefix("s", "msg", key("c"))
    let viaId = aw3.get()
    let aw4 = await j.scanPrefix("msg", key("c"))
    let viaRef = aw4.get()
    check viaId.len == viaRef.len
    for i in 0 ..< viaId.len:
      check viaId[i].key == viaRef[i].key
      check viaId[i].payload == viaRef[i].payload
