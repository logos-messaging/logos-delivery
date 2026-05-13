{.used.}

import std/[options, os, times]
import chronos, results
import testutils/unittests
import brokers/[event_broker, request_broker]
import waku/persistency/persistency
import waku/persistency/backend_comm

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
proc waitFor(t: Job, category: string, k: Key, timeoutMs = 1000): bool =
  let deadline = epochTime() + (timeoutMs.float / 1000.0)
  while epochTime() < deadline:
    let r = waitFor KvExists.request(t.context, category, k)
    if r.isOk and r.get().value:
      return true
    sleep(2)
  false

procSuite "Persistency lifecycle":
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

  test "openJob reuses an existing DB file across processes-of-one":
    let root = tmpRoot("reopen")
    defer:
      removeDir(root)

    # First "session": write something then close.
    block firstSession:
      let p = Persistency.instance(root).get()
      let j = p.openJob("persist").get()
      j.persistPut("msg", key("c", 1'i64), payloadBytes("v1"))
      check j.waitFor("msg", key("c", 1'i64))
      Persistency.reset()

    check fileExists(root / "persist.db")

    # Second "session": reopen and read the data back.
    block secondSession:
      let p = Persistency.instance(root).get()
      defer:
        Persistency.reset()
      let j = p.openJob("persist").get()
      let got = (waitFor KvGet.request(j.context, "msg", key("c", 1'i64))).get()
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

  test "Persistency.instance creates rootDir and openJob launches a worker":
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

  test "persist then read round-trips via brokers":
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
    waitFor PersistEvent.emit(t.context, ev)
    check t.waitFor("msg", k)

    let got = (waitFor KvGet.request(t.context, "msg", k)).get()
    check got.value.isSome
    check str(got.value.get) == "hello"

  test "two jobs run in parallel with isolated DBs":
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
    waitFor PersistEvent.emit(
      a.context,
      PersistEvent(
        ops: @[
          TxOp(
            category: "msg", key: k, kind: txPut, payload: payloadBytes("from-alpha")
          )
        ]
      ),
    )
    waitFor PersistEvent.emit(
      b.context,
      PersistEvent(
        ops: @[
          TxOp(category: "msg", key: k, kind: txPut, payload: payloadBytes("from-beta"))
        ]
      ),
    )
    check a.waitFor("msg", k)
    check b.waitFor("msg", k)

    let aGot = (waitFor KvGet.request(a.context, "msg", k)).get()
    let bGot = (waitFor KvGet.request(b.context, "msg", k)).get()
    check str(aGot.value.get) == "from-alpha"
    check str(bGot.value.get) == "from-beta"

    # Each job has its own DB file.
    check fileExists(root / "alpha.db")
    check fileExists(root / "beta.db")

  test "closeJob joins the worker and frees the slot":
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
    let r = waitFor KvExists.request(ctx, "msg", key("k"))
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

  test "scan and count over a range":
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
    waitFor PersistEvent.emit(t.context, PersistEvent(ops: ops))
    # Wait for the last insert to land.
    check t.waitFor("msg", key("c", 5'i64))

    let rng = prefixRange(key("c"))
    let cnt = (waitFor KvCount.request(t.context, "msg", rng)).get()
    check cnt.n == 5

    let scn = (waitFor KvScan.request(t.context, "msg", rng, false)).get()
    check scn.rows.len == 5
    check str(scn.rows[0].payload) == "1"
    check str(scn.rows[4].payload) == "5"

  test "acked delete reports whether the row existed":
    let root = tmpRoot("delete")
    defer:
      removeDir(root)
    let p = Persistency.instance(root).get()
    defer:
      Persistency.reset()
    let t = p.openJob("t").get()

    let k = key("d", 1'i64)
    let r1 = (waitFor KvDelete.request(t.context, "msg", k)).get()
    check r1.existed == false

    waitFor PersistEvent.emit(
      t.context,
      PersistEvent(
        ops: @[TxOp(category: "msg", key: k, kind: txPut, payload: payloadBytes("v"))]
      ),
    )
    check t.waitFor("msg", k)

    let r2 = (waitFor KvDelete.request(t.context, "msg", k)).get()
    check r2.existed == true
    let r3 = (waitFor KvExists.request(t.context, "msg", k)).get()
    check r3.value == false
