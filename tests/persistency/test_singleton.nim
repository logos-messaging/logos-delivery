{.used.}

import std/[os, strutils, times]
import chronos, results
import testutils/unittests
import brokers/[request_broker, broker_context]
import logos_delivery/waku/persistency/persistency

proc tmpRoot(label: string): string =
  let p = getTempDir() / ("persistency_instance_" & label & "_" & $epochTime().int)
  removeDir(p)
  p

suite "Persistency instances":
  test "new(rootDir) builds independent instances":
    let rootA = tmpRoot("a")
    let rootB = tmpRoot("b")
    defer:
      removeDir(rootA)
    defer:
      removeDir(rootB)

    let pA = Persistency.new(rootA).get()
    let pB = Persistency.new(rootB).get()
    defer:
      pA.close()
    defer:
      pB.close()

    check pA.rootDir == rootA
    check pB.rootDir == rootB
    check pA != pB

  test "new(rootDir) with the same rootDir yields distinct instances":
    let root = tmpRoot("same")
    defer:
      removeDir(root)

    let p1 = Persistency.new(root).get()
    let p2 = Persistency.new(root).get()
    defer:
      p1.close()
    defer:
      p2.close()

    check p1 != p2

  test "close() is idempotent":
    let root = tmpRoot("close")
    defer:
      removeDir(root)

    let p = Persistency.new(root).get()
    discard p.openJob("j").get()
    p.close()
    p.close()
    check not p.hasJob("j")

suite "GetPersistency broker":
  test "request fails when no provider is installed":
    let ctx = NewBrokerContext()
    check GetPersistency.request(ctx).isErr

  test "request returns the provided instance, clearProvider removes it":
    let root = tmpRoot("broker")
    defer:
      removeDir(root)

    let ctx = NewBrokerContext()
    let p = Persistency.new(root).get()
    defer:
      p.close()

    discard GetPersistency.reprovideIt(ctx):
      ok(p)

    let got = GetPersistency.request(ctx)
    check got.isOk
    check got.get() == p

    GetPersistency.clearProvider(ctx)
    check GetPersistency.request(ctx).isErr

  test "providers on different contexts resolve different instances":
    let rootA = tmpRoot("ctx-a")
    let rootB = tmpRoot("ctx-b")
    defer:
      removeDir(rootA)
    defer:
      removeDir(rootB)

    let ctxA = NewBrokerContext()
    let ctxB = NewBrokerContext()
    let pA = Persistency.new(rootA).get()
    let pB = Persistency.new(rootB).get()
    defer:
      pA.close()
    defer:
      pB.close()

    discard GetPersistency.reprovideIt(ctxA):
      ok(pA)
    discard GetPersistency.reprovideIt(ctxB):
      ok(pB)
    defer:
      GetPersistency.clearProvider(ctxA)
    defer:
      GetPersistency.clearProvider(ctxB)

    check GetPersistency.request(ctxA).get() == pA
    check GetPersistency.request(ctxB).get() == pB
