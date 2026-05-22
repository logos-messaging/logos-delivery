{.used.}

import std/[os, strutils, times]
import chronos, results
import testutils/unittests
import brokers/multi_request_broker
import waku/persistency/persistency

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
