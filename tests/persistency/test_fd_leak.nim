{.used.}

## A closed job must give back every fd it opened (#4498): the SQLite
## database with its -wal/-shm files, and the worker thread's chronos
## dispatcher (selector plus wake-up fd).

import std/[os, times]
import chronos, results
import testutils/unittests
import brokers/request_broker
import logos_delivery/waku/persistency/persistency
import logos_delivery/waku/persistency/backend_comm

const FdDir =
  when defined(linux):
    "/proc/self/fd"
  elif defined(macosx):
    "/dev/fd"
  else:
    ""

proc openFds(): int =
  for _ in walkDir(FdDir):
    inc result

proc runJobCycle(root: string) =
  ## Open the job, write a row and read it back, so the database, its WAL
  ## and the shared-memory index are all open, then close everything.
  let p = Persistency.new(root).expect("new persistency")
  let job = p.openJob("messaging").expect("open job")
  let key = toKey("k")
  waitFor job.persistPut("c", key, @[byte 1, 2, 3])
  let deadline = epochTime() + 2.0
  var written = false
  while not written and epochTime() < deadline:
    let r = waitFor KvExists.request(job.context, "c", key)
    written = r.isOk() and r.get().value
    if not written:
      waitFor sleepAsync(chronos.milliseconds(2))
  check written
  p.close()

suite "Persistency - fd release":
  test "open/close cycles do not leak fds":
    when FdDir.len == 0:
      skip()
    else:
      let base = getTempDir() / ("persistency_fd_" & $epochTime().int)
      defer:
        removeDir(base)

      ## The first cycle also creates this thread's own dispatcher, which
      ## stays; measure from after it.
      runJobCycle(base / "warmup")
      let before = openFds()

      ## A fresh root per cycle, as a host recreating its node does.
      for i in 0 ..< 5:
        runJobCycle(base / $i)
        check fileExists(base / $i / "messaging.db")

      check openFds() == before
