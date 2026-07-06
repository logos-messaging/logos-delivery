{.used.}

import std/[options, os, times]
import chronos, results
import testutils/unittests
import brokers/[event_broker, request_broker]
import logos_delivery/waku/persistency/persistency
import logos_delivery/waku/persistency/backend_comm

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
  let p = getTempDir() / ("persistency_test_" & label & "_" & $epochTime().int)
  removeDir(p)
  p

# Cross-thread persist: emit a PersistEvent then poll until the row shows up
# via KvExists. The PersistEvent listener is fire-and-forget, so reads
# immediately after emit are racy by design (documented in v1).
proc pollExists(
    t: Job, category: string, k: Key, timeoutMs = 1000
): Future[bool] {.async.} =
  let deadline = epochTime() + (timeoutMs.float / 1000.0)
  while epochTime() < deadline:
    let r = await KvExists.request(t.context, category, k)
    if r.isOk and r.get().value:
      return true
    await sleepAsync(chronos.milliseconds(2))
  return false

suite "Persistency lifecycle":
  test "Persistency.instance accepts a pre-existing rootDir":
    let root = tmpRoot("preexisting")
    defer:
      removeDir(root)
    createDir(root) # pretend a previous run left it
    let marker = root / "do-not-touch.txt"
    writeFile(marker, "hi")
    defer:
      removeFile(marker)

    let p = Persistency.instance(root).get()
    defer:
      Persistency.reset()
    # The pre-existing file is untouched.
    check fileExists(marker)
    check readFile(marker) == "hi"

  test "Persistency.instance refuses a non-directory path":
    let root = tmpRoot("collision")
    defer:
      removeFile(root)
    writeFile(root, "im a file not a dir") # collide with rootDir name
    let r = Persistency.instance(root)
    check r.isErr
    check r.error.kind == peInvalidArgument

  test "Persistency.instance defers rootDir creation until first openJob":
    let root = tmpRoot("lazy")
    defer:
      removeDir(root)
    check not dirExists(root)

    let p = Persistency.instance(root).get()
    defer:
      Persistency.reset()
    # instance() must not have touched the filesystem
    check not dirExists(root)

    discard p.openJob("first").get()
    # first openJob materialises the directory
    check dirExists(root)

  test "Persistency.instance refuses a path whose ancestor is not a directory":
    let parent = tmpRoot("bad-parent")
    defer:
      removeFile(parent)
    writeFile(parent, "not a directory")
    let root = parent / "child"
    let r = Persistency.instance(root)
    check r.isErr
    check r.error.kind == peInvalidArgument

  asyncTest "openJob reuses an existing DB file across processes-of-one":
    let root = tmpRoot("reopen")
    defer:
      removeDir(root)

    # First "session": write something then close.
    block firstSession:
      let p = Persistency.instance(root).get()
      let j = p.openJob("persist").get()
      await j.persistPut("msg", key("c", 1'i64), payloadBytes("v1"))
      let ckOk1 = await j.pollExists("msg", key("c", 1'i64))
      check ckOk1
      Persistency.reset()

    check fileExists(root / "persist.db")

    # Second "session": reopen and read the data back.
    block secondSession:
      let p = Persistency.instance(root).get()
      defer:
        Persistency.reset()
      let j = p.openJob("persist").get()
      let aw1 = await KvGet.request(j.context, "msg", key("c", 1'i64))
      let got = aw1.get()
      check got.value.isSome
      check str(got.value.get) == "v1"

  test "openJob is idempotent within a session":
    let root = tmpRoot("idem")
    defer:
      removeDir(root)
    let p = Persistency.instance(root).get()
    defer:
      Persistency.reset()
    let a = p.openJob("same").get()
    let b = p.openJob("same").get()
    check a.id == b.id
    check a.context == b.context

  test "openJob materialises rootDir and launches a worker":
    let root = tmpRoot("basic")
    defer:
      removeDir(root)

    let p = Persistency.instance(root).get()
    defer:
      Persistency.reset()

    let t = p.openJob("alpha").get()
    check t.id == "alpha"
    check t.running
    check fileExists(root / "alpha.db")

  asyncTest "persist then read round-trips via brokers":
    let root = tmpRoot("rw")
    defer:
      removeDir(root)
    let p = Persistency.instance(root).get()
    defer:
      Persistency.reset()
    let t = p.openJob("t1").get()

    let k = key("c", 1'i64)
    let ev = PersistEvent(
      ops: @[TxOp(category: "msg", key: k, kind: txPut, payload: payloadBytes("hello"))]
    )
    PersistEvent.emit(t.context, ev)
    let ckOk2 = await t.pollExists("msg", k)
    check ckOk2

    let aw2 = await KvGet.request(t.context, "msg", k)
    let got = aw2.get()
    check got.value.isSome
    check str(got.value.get) == "hello"

  asyncTest "two jobs run in parallel with isolated DBs":
    let root = tmpRoot("isolation")
    defer:
      removeDir(root)
    let p = Persistency.instance(root).get()
    defer:
      Persistency.reset()

    let a = p.openJob("alpha").get()
    let b = p.openJob("beta").get()
    check a.context != b.context

    let k = key("shared", 1'i64)
    PersistEvent.emit(
      a.context,
      PersistEvent(
        ops: @[
          TxOp(
            category: "msg", key: k, kind: txPut, payload: payloadBytes("from-alpha")
          )
        ]
      ),
    )
    PersistEvent.emit(
      b.context,
      PersistEvent(
        ops: @[
          TxOp(category: "msg", key: k, kind: txPut, payload: payloadBytes("from-beta"))
        ]
      ),
    )
    let ckOk3 = await a.pollExists("msg", k)
    check ckOk3
    let ckOk4 = await b.pollExists("msg", k)
    check ckOk4

    let aw3 = await KvGet.request(a.context, "msg", k)
    let aGot = aw3.get()
    let aw4 = await KvGet.request(b.context, "msg", k)
    let bGot = aw4.get()
    check str(aGot.value.get) == "from-alpha"
    check str(bGot.value.get) == "from-beta"

    # Each job has its own DB file.
    check fileExists(root / "alpha.db")
    check fileExists(root / "beta.db")

  asyncTest "closeJob joins the worker and frees the slot":
    let root = tmpRoot("close")
    defer:
      removeDir(root)
    let p = Persistency.instance(root).get()
    defer:
      Persistency.reset()

    let t = p.openJob("x").get()
    let ctx = t.context
    p.closeJob("x")
    check not t.running

    # After close, requests on the old context have no provider.
    let r = await KvExists.request(ctx, "msg", key("k"))
    check r.isErr

  test "dropJob removes the DB file":
    let root = tmpRoot("drop")
    defer:
      removeDir(root)
    let p = Persistency.instance(root).get()
    defer:
      Persistency.reset()
    discard p.openJob("ephemeral").get()
    check fileExists(root / "ephemeral.db")
    p.dropJob("ephemeral")
    check not fileExists(root / "ephemeral.db")

  asyncTest "scan and count over a range":
    let root = tmpRoot("scan")
    defer:
      removeDir(root)
    let p = Persistency.instance(root).get()
    defer:
      Persistency.reset()
    let t = p.openJob("t").get()

    var ops: seq[TxOp]
    for i in 1'i64 .. 5:
      ops.add(
        TxOp(category: "msg", key: key("c", i), kind: txPut, payload: payloadBytes($i))
      )
    PersistEvent.emit(t.context, PersistEvent(ops: ops))
    # Wait for the last insert to land.
    let ckOk5 = await t.pollExists("msg", key("c", 5'i64))
    check ckOk5

    let rng = prefixRange(key("c"))
    let aw5 = await KvCount.request(t.context, "msg", rng)
    let cnt = aw5.get()
    check cnt.n == 5

    let aw6 = await KvScan.request(t.context, "msg", rng, false)
    let scn = aw6.get()
    check scn.rows.len == 5
    check str(scn.rows[0].payload) == "1"
    check str(scn.rows[4].payload) == "5"

  asyncTest "acked delete reports whether the row existed":
    let root = tmpRoot("delete")
    defer:
      removeDir(root)
    let p = Persistency.instance(root).get()
    defer:
      Persistency.reset()
    let t = p.openJob("t").get()

    let k = key("d", 1'i64)
    let aw7 = await KvDelete.request(t.context, "msg", k)
    let r1 = aw7.get()
    check r1.existed == false

    PersistEvent.emit(
      t.context,
      PersistEvent(
        ops: @[TxOp(category: "msg", key: k, kind: txPut, payload: payloadBytes("v"))]
      ),
    )
    let ckOk6 = await t.pollExists("msg", k)
    check ckOk6

    let aw8 = await KvDelete.request(t.context, "msg", k)
    let r2 = aw8.get()
    check r2.existed == true
    let aw9 = await KvExists.request(t.context, "msg", k)
    let r3 = aw9.get()
    check r3.value == false
