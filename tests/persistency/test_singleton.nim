{.used.}

import std/[os, strutils, times]
import chronos, results
import testutils/unittests
import brokers/multi_request_broker
import waku/persistency/persistency
import waku/requests/lifecycle_requests

proc tmpRoot(label: string): string =
  let p = getTempDir() / ("persistency_singleton_" & label & "_" & $epochTime().int)
  removeDir(p)
  p

suite "Persistency singleton":
  test "instance(rootDir) is idempotent with the same rootDir":
    let root = tmpRoot("idem")
    defer:
      removeDir(root)
    defer:
      Persistency.reset()

    let p1 = Persistency.instance(root).get()
    let p2 = Persistency.instance(root).get()
    check p1 == p2

  test "instance(rootDir) refuses re-init with a different rootDir":
    let rootA = tmpRoot("a")
    let rootB = tmpRoot("b")
    defer:
      removeDir(rootA)
    defer:
      removeDir(rootB)
    defer:
      Persistency.reset()

    discard Persistency.instance(rootA).get()
    let r = Persistency.instance(rootB)
    check r.isErr
    check r.error.kind == peInvalidArgument

  test "no-arg instance() fails before init, succeeds after":
    let root = tmpRoot("noarg")
    defer:
      removeDir(root)
    defer:
      Persistency.reset()

    let before = Persistency.instance()
    check before.isErr
    check before.error.kind == peClosed

    discard Persistency.instance(root).get()
    let after = Persistency.instance()
    check after.isOk

  test "reset() makes the next instance() target a different rootDir":
    let rootA = tmpRoot("rs-a")
    let rootB = tmpRoot("rs-b")
    defer:
      removeDir(rootA)
    defer:
      removeDir(rootB)
    defer:
      Persistency.reset()

    let pA = Persistency.instance(rootA).get()
    check pA.rootDir == rootA
    Persistency.reset()

    let pB = Persistency.instance(rootB).get()
    check pB.rootDir == rootB
    check pA != pB

  test "reset() is idempotent":
    defer:
      Persistency.reset()
    Persistency.reset()
    Persistency.reset()
    check Persistency.instance().isErr

  asyncTest "Teardown.request closes the singleton and fires our provider":
    let root = tmpRoot("teardown")
    defer:
      removeDir(root)
    defer:
      Persistency.reset() # belt-and-braces in case the request path fails

    let p = Persistency.instance(root).get()
    discard p.openJob("alpha").get()
    discard p.openJob("beta").get()
    check p.hasJob("alpha")
    check p.hasJob("beta")

    let res = await Teardown.request()
    check res.isOk
    let components = res.get()
    # Our provider returns one Teardown value mentioning both job ids.
    check components.len >= 1
    var foundPersistency = false
    for c in components:
      if c.component.startsWith("persistency jobs:"):
        foundPersistency = true
    check foundPersistency

    # The singleton slot is now clear -- next instance() with the same
    # rootDir produces a fresh instance.
    let p2 = Persistency.instance(root).get()
    check p2 != p
    check not p2.hasJob("alpha")
