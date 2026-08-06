{.used.}

## Regression guard for the former singleton thread-affinity defect
## (channel_lifecycle.sdsPersistence -> openJob -> tables.rawGet SIGSEGV):
## a process-global `gPersistency` was allocated on whichever FFI thread
## first touched it, and under `--mm:refc` outlived that thread's heap.
##
## Post-refactor semantics under test:
##   * a `Persistency` instance is created, used and closed entirely on
##     its owning thread -- nothing is process-global anymore. The owner
##     drives two in-memory jobs end to end: two storage workers are
##     spun up, written to and read back through their broker contexts,
##     then torn down (one via `closeJob`, the rest via `close`) before
##     the owning thread exits.
##   * the `GetPersistency` broker is context- AND thread-scoped
##     (single-thread RequestBroker registries are threadvars), so a
##     second thread cannot reach the owner's instance -- not even when
##     it knows the owner's `BrokerContext` id.

import std/times
import chronos, results
import testutils/unittests
import brokers/[request_broker, broker_context]
import logos_delivery/waku/persistency/persistency

var
  ownerCtx: BrokerContext
    ## distinct uint32 (POD); safe to hand across threads -- reading it
    ## from the second thread is exactly the escape hatch under test.
  ownerFailed: bool
  userReachedInstance: bool
    ## Plain bools (no GC'd payload) so the worker threads can set them;
    ## joinThread orders the writes before the main-thread checks.

proc payload(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s:
    result[i] = byte(c)

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

proc fail(msg: string) =
  echo "  FAIL: ", msg
  ownerFailed = true

proc exerciseJobs(p: Persistency) {.async.} =
  ## Two jobs => two storage worker threads, each with a private
  ## in-memory database. Round-trip a write through each, prove they are
  ## independent, then tear one down explicitly.
  let a = p.openJob("a").expect("openJob a")
  let b = p.openJob("b").expect("openJob b")
  if a.context == b.context:
    fail("jobs must run under distinct broker contexts")

  let k = key("aff", 1'i64)
  await a.persistPut("msg", k, payload("via-a"))
  await b.persistPut("msg", k, payload("via-b"))

  if not await a.waitUntilExists("msg", k):
    fail("job a never saw its own write")
  if not await b.waitUntilExists("msg", k):
    fail("job b never saw its own write")

  ## Private per-worker :memory: databases: same key, different payloads.
  let fromA = (await a.get("msg", k)).expect("get via a")
  let fromB = (await b.get("msg", k)).expect("get via b")
  if fromA.isNone or fromA.get() != payload("via-a"):
    fail("job a returned the wrong payload")
  if fromB.isNone or fromB.get() != payload("via-b"):
    fail("job b returned the wrong payload")

  ## Explicit single-job teardown joins its worker thread.
  p.closeJob("a")
  if p.hasJob("a"):
    fail("job a still open after closeJob")
  if not p.hasJob("b"):
    fail("job b must survive closing job a")

  ## The surviving worker still answers after a sibling teardown.
  if not await b.waitUntilExists("msg", k):
    fail("job b stopped answering after job a closed")

proc ownerThread(unused: int) {.thread.} =
  ## Stands in for the FFI thread owning a node: create the instance,
  ## exercise its jobs, provide it under this thread's context, resolve
  ## it via the broker, then tear everything down before the thread exits.
  let ctx = NewBrokerContext()
  ownerCtx = ctx

  let p = Persistency.new(InMemoryStoragePath).expect("Persistency.new on owner thread")

  try:
    waitFor exerciseJobs(p)
  except CatchableError as e:
    fail("exerciseJobs raised: " & e.msg)

  discard GetPersistency.reprovideIt(ctx):
    ok(p)

  let r = GetPersistency.request(ctx)
  if r.isErr() or r.get() != p or not r.get().hasJob("b"):
    fail("same-thread broker resolution broken")

  GetPersistency.clearProvider(ctx)
  ## Joins job b's worker thread; owner heap objects die with this thread.
  p.close()
  if p.hasJob("b"):
    fail("job b still open after close")

proc userThread(unused: int) {.thread.} =
  ## Stands in for a second FFI thread with a fresh heap. There must be
  ## no path to the first thread's instance: neither via its context id
  ## nor via any fresh context.
  let viaOwnerCtx = GetPersistency.request(ownerCtx)
  if viaOwnerCtx.isOk():
    echo "  FAIL: owner's instance reachable from another thread via its ctx"
    userReachedInstance = true

  let viaFreshCtx = GetPersistency.request(NewBrokerContext())
  if viaFreshCtx.isOk():
    echo "  FAIL: an instance is reachable through a fresh context"
    userReachedInstance = true

suite "Persistency - thread affinity":
  test "instance, jobs and broker provider are confined to the owning thread":
    var owner: Thread[int]
    createThread(owner, ownerThread, 0)
    joinThread(owner)
    check not ownerFailed

    var user: Thread[int]
    createThread(user, userThread, 0)
    joinThread(user)
    check not userReachedInstance
