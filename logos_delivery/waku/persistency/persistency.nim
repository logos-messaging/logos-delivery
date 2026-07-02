import logos_delivery/waku/compat/option_valueor
## Public facade and main driver types for the persistency library.
##
## ``Persistency`` is the per-root coordinator; one instance owns one
## directory and any number of named jobs. ``Job`` is the per-job handle:
## one tenant, one DB file, one worker thread, one BrokerContext.
##
## ## Two ways to drive a job
##
## **By Job ref** — capture the handle from `openJob` and call methods on
## it. Cheapest, no map lookup per call:
##
## ```nim
## let p = Persistency.instance("/var/lib/wakustore").get()
## let j = p.openJob("alpha").get()
## await j.persistPut("msg", k, payload)
## let v = await j.get("msg", k)
## ```
##
## **By job id string** — useful when the caller doesn't want to thread
## the ``Job`` ref around (config-driven services, RPC dispatchers). The
## Job must still have been opened previously; the string-form procs look
## it up in `Persistency.jobs`:
##
## ```nim
## discard p.openJob("alpha")
## await p.persistPut("alpha", "msg", k, payload)   # logs and resolves if not open
## let v = await p.get("alpha", "msg", k)           # Result, peJobNotFound if missing
## ```
##
## ## Drain semantics
##
## Writes return a ``Future[void]`` that resolves once the PersistEvent
## has been pushed onto the worker thread's channel — **not** once the
## SQL has run. The listener is still fire-and-forget on the SQL side, so
## a read issued immediately after an awaited write is still racy by
## design in v1. To bridge the race:
##   * use ``deleteAcked`` (it round-trips through the read path), or
##   * poll ``exists`` until it returns true, or
##   * yield with ``await sleepAsync(...)``.

{.push raises: [].}

import std/[locks, options, os, sequtils, tables]
import chronos, chronicles, results
import brokers/[event_broker, request_broker, broker_context]
import ./[types, keys, payload, backend_comm, backend_thread]

export types, keys, payload

logScope:
  topics = "persistency"

const DefaultStoragePath* = "./data"

# ── Driver types ────────────────────────────────────────────────────────

type
  Job* = ref object
    ## Per-job handle. Owns its BrokerContext and the worker thread that
    ## services it. Created and torn down via `Persistency.openJob` /
    ## `Persistency.closeJob`.
    id*: string
    context*: BrokerContext
    runtime: JobRuntime ## internal — managed by openJob/closeJob
    running*: bool

  Persistency* = ref object
    ## Per-root coordinator. One Persistency instance manages a directory
    ## of per-job SQLite files at ``rootDir/<jobId>.db``.
    rootDir*: string
    jobs*: Table[string, Job]

# ── Singleton state ─────────────────────────────────────────────────────
#
# Persistency is a process-wide singleton: one rootDir at a time. The
# `instance` factory is the only public constructor; `new` below is
# private and skips the singleton bookkeeping (used internally and never
# called twice with conflicting rootDirs).

var
  gPersistency {.global.}: Persistency
  gPersistencyLock {.global.}: Lock

once:
  gPersistencyLock.initLock()

# ── Lifecycle ───────────────────────────────────────────────────────────

proc dbPathFor(p: Persistency, jobId: string): string =
  p.rootDir / (jobId & ".db")

proc new(T: type Persistency, rootDir: string): Result[T, PersistencyError] =
  ## Private. Build a Persistency value without touching the singleton
  ## slot. Validates ``rootDir`` but does **not** create it — directory
  ## materialisation is deferred to the first ``openJob`` call. Semantics:
  ##
  ## * If ``rootDir`` is empty, returns ``peInvalidArgument``.
  ## * If ``rootDir`` exists and is a directory, accept it.
  ## * If ``rootDir`` exists but is not a directory, returns
  ##   ``peInvalidArgument``.
  ## * If ``rootDir`` does not exist, walk up the parent chain: the first
  ##   existing ancestor must be a directory; otherwise returns
  ##   ``peInvalidArgument``. This catches "obviously broken" paths early
  ##   without actually touching the filesystem.
  if rootDir.len == 0:
    return err(persistencyErr(peInvalidArgument, "rootDir is empty"))
  if fileExists(rootDir) and not dirExists(rootDir):
    return err(
      persistencyErr(
        peInvalidArgument, "rootDir exists and is not a directory: " & rootDir
      )
    )
  if not dirExists(rootDir):
    var parent = parentDir(rootDir)
    while parent.len > 0 and not dirExists(parent):
      if fileExists(parent):
        return err(
          persistencyErr(
            peInvalidArgument,
            "rootDir ancestor exists and is not a directory: " & parent,
          )
        )
      parent = parentDir(parent)
  return ok(T(rootDir: rootDir, jobs: initTable[string, Job]()))

proc ensureRootDir(p: Persistency): Result[void, PersistencyError] =
  ## Materialise ``rootDir`` on demand. Idempotent; called from
  ## ``openJob`` so an unused Persistency leaves no directory behind.
  if dirExists(p.rootDir):
    return ok()
  try:
    createDir(p.rootDir)
  except OSError, IOError:
    return
      err(persistencyErr(peBackend, "createDir failed: " & getCurrentExceptionMsg()))
  return ok()

proc reset*(T: type Persistency) {.gcsafe.} =
  ## Tear down the singleton: close every open job, clear the Teardown
  ## provider, and free the slot so a subsequent ``Persistency.instance``
  ## starts fresh. Idempotent. Tests use this in `defer`;.
  {.cast(gcsafe).}:
    acquire(gPersistencyLock)
    defer:
      release(gPersistencyLock)
    if gPersistency != nil:
      let p = gPersistency
      gPersistency = nil
      p.close()

proc instance*(
    T: type Persistency, rootDir: string
): Result[T, PersistencyError] {.gcsafe.} =
  ## Get-or-init the process-wide Persistency singleton.
  ##
  ## * First call: validates ``rootDir`` (without creating it) and
  ##   registers the Teardown handler. The directory itself is created
  ##   lazily by the first ``openJob`` call, so a Persistency that never
  ##   opens a job leaves no filesystem footprint.
  ## * Later calls with the same ``rootDir``: returns the live instance
  ##   (idempotent).
  ## * Later calls with a different ``rootDir``: returns
  ##   ``peInvalidArgument`` — the singleton can only be re-targeted via
  ##   ``Persistency.reset`` (or by the Teardown shutdown flow).
  {.cast(gcsafe).}:
    acquire(gPersistencyLock)
    defer:
      release(gPersistencyLock)

    if gPersistency != nil:
      if gPersistency.rootDir == rootDir:
        return ok(gPersistency)
      return err(
        persistencyErr(
          peInvalidArgument,
          "Persistency already initialised with rootDir " & gPersistency.rootDir &
            "; cannot re-init with " & rootDir,
        )
      )

    let p = ?Persistency.new(rootDir)
    gPersistency = p
    return ok(p)

proc instance*(T: type Persistency): Result[T, PersistencyError] {.gcsafe.} =
  ## No-args form: succeeds only if the singleton is already initialised.
  ## Use this from services that must not be the first to touch
  ## persistency.
  {.cast(gcsafe).}:
    acquire(gPersistencyLock)
    defer:
      release(gPersistencyLock)
    if gPersistency.isNil:
      return err(persistencyErr(peClosed, "Persistency not initialised"))
    return ok(gPersistency)

proc openJob*(p: Persistency, jobId: string): Result[Job, PersistencyError] =
  ## Open-or-create a job under this Persistency.
  ##
  ## * If the job is already open in this process, the existing ``Job``
  ##   ref is returned (idempotent).
  ## * Otherwise ``rootDir`` is materialised on demand (created with
  ##   missing parents on first use; no-op on subsequent calls), a worker
  ##   thread is spawned, and the SQLite file at
  ##   ``<rootDir>/<jobId>.db`` is opened. If the file does not exist it
  ##   is created and the schema initialised; if it already exists it is
  ##   reopened in place and its data is preserved.
  let existing = p.jobs.getOrDefault(jobId, nil)
  if existing != nil:
    return ok(existing)

  ?p.ensureRootDir()

  let ctx = NewBrokerContext()
  let rt = ?startStorageThread(ctx, dbPathFor(p, jobId))
  let job = Job(id: jobId, context: ctx, runtime: rt, running: true)
  p.jobs[jobId] = job
  return ok(job)

proc closeJob*(p: Persistency, jobId: string) =
  ## Stop the worker, join its thread, and forget the job. No-op if the
  ## job isn't open.
  let job = p.jobs.getOrDefault(jobId, nil)
  if job == nil:
    return
  stopStorageThread(job.runtime)
  job.runtime = nil
  job.running = false
  p.jobs.del(jobId)

proc close*(p: Persistency) =
  ## Close every open job. Idempotent.
  var ids: seq[string]
  for id in p.jobs.keys:
    ids.add(id)
  for id in ids:
    p.closeJob(id)

proc dropJob*(p: Persistency, jobId: string) =
  ## Close the job if open, then delete its DB file (plus -wal / -shm
  ## sidecars). Best-effort: a missing file is not an error.
  p.closeJob(jobId)
  let path = dbPathFor(p, jobId)
  for suffix in ["", "-wal", "-shm"]:
    try:
      removeFile(path & suffix)
    except OSError, IOError:
      discard

# ── String lookup ───────────────────────────────────────────────────────

proc job*(p: Persistency, jobId: string): Result[Job, PersistencyError] =
  ## Look up an already-open job. Returns ``peJobNotFound`` if no such
  ## job has been opened (``openJob`` first).
  let j = p.jobs.getOrDefault(jobId, nil)
  if j != nil:
    return ok(j)
  else:
    return err(persistencyErr(peJobNotFound, "no open job with id: " & jobId))

proc `[]`*(p: Persistency, jobId: string): Job {.raises: [KeyError].} =
  ## Subscript sugar for `job` — raises ``KeyError`` if the job isn't
  ## open. Prefer `job(p, id)` when you want a typed error.
  p.jobs[jobId]

proc hasJob*(p: Persistency, jobId: string): bool {.inline.} =
  p.jobs.hasKey(jobId)

# ── Writes (fire-and-forget) — Job form ─────────────────────────────────

proc persist*(t: Job, ops: seq[TxOp]): Future[void] {.async.} =
  ## Emit a batched persist event. The handler treats >1 ops as a single
  ## BEGIN IMMEDIATE/COMMIT transaction (see backend_sqlite.applyOps).
  PersistEvent.emit(t.context, PersistEvent(ops: ops))

proc persist*(t: Job, op: TxOp): Future[void] {.async.} =
  await persist(t, @[op])

proc persistPut*(
    t: Job, category: string, key: Key, payload: seq[byte]
): Future[void] {.async.} =
  await persist(t, TxOp(category: category, key: key, kind: txPut, payload: payload))

proc persistDelete*(t: Job, category: string, key: Key): Future[void] {.async.} =
  await persist(t, TxOp(category: category, key: key, kind: txDelete))

proc persistDeletePrefix*(
    t: Job, category: string, prefix: Key
): Future[void] {.async.} =
  await persist(t, TxOp(category: category, key: prefix, kind: txDeletePrefix))

proc persistEncoded*[T](
    t: Job, category: string, key: Key, value: T
): Future[void] {.async.} =
  ## Convenience: encode `value` via `toPayload` and put it. Use the raw
  ## `persistPut(..., seq[byte])` form when you already have bytes
  ## (e.g. an externally-produced CBOR blob).
  await persistPut(t, category, key, toPayload(value))

# ── Writes (fire-and-forget) — string-lookup form ───────────────────────
#
# These look up the Job by id and dispatch. If the job isn't open we log
# a warning and drop the write — consistent with the fire-and-forget
# contract; the caller has no return channel to inspect.

proc jobOrWarn(p: Persistency, jobId: string): Job =
  ## Lookup helper for the fire-and-forget write paths. Returns nil and
  ## logs a warning if the job isn't open. Isolated as a non-generic proc
  ## so chronicles' `warn` macro expands cleanly (it doesn't, when called
  ## from inside a generic proc's body).
  let job = p.jobs.getOrDefault(jobId, nil)
  if job.isNil():
    warn "persistency: write dropped, job not open", jobId
  return job

template withJobOrWarn(p: Persistency, jobId: string, j, body: untyped) =
  let `j` = p.jobOrWarn(jobId)
  if not `j`.isNil():
    body

proc persist*(p: Persistency, jobId: string, ops: seq[TxOp]): Future[void] {.async.} =
  let j = p.jobOrWarn(jobId)
  if not j.isNil():
    await j.persist(ops)

proc persist*(p: Persistency, jobId: string, op: TxOp): Future[void] {.async.} =
  await p.persist(jobId, @[op])

proc persistPut*(
    p: Persistency, jobId: string, category: string, key: Key, payload: seq[byte]
): Future[void] {.async.} =
  let j = p.jobOrWarn(jobId)
  if not j.isNil():
    await j.persistPut(category, key, payload)

proc persistDelete*(
    p: Persistency, jobId: string, category: string, key: Key
): Future[void] {.async.} =
  let j = p.jobOrWarn(jobId)
  if not j.isNil():
    await j.persistDelete(category, key)

proc persistDeletePrefix*(
    p: Persistency, jobId: string, category: string, prefix: Key
): Future[void] {.async.} =
  let j = p.jobOrWarn(jobId)
  if not j.isNil():
    await j.persistDeletePrefix(category, prefix)

proc persistEncoded*[T](
    p: Persistency, jobId: string, category: string, key: Key, value: T
): Future[void] {.async.} =
  let j = p.jobOrWarn(jobId)
  if not j.isNil():
    await j.persistEncoded(category, key, value)

# ── Reads (async, typed errors) — Job form ──────────────────────────────

template liftErr(s: string): PersistencyError =
  decodeErr(s)

proc get*(
    t: Job, category: string, key: Key
): Future[Result[Option[seq[byte]], PersistencyError]] {.async.} =
  let r = (await KvGet.request(t.context, category, key)).valueOr:
    return err(liftErr(error))
  return ok(r.value)

proc exists*(
    t: Job, category: string, key: Key
): Future[Result[bool, PersistencyError]] {.async.} =
  let r = (await KvExists.request(t.context, category, key)).valueOr:
    return err(liftErr(error))
  return ok(r.value)

proc scan*(
    t: Job, category: string, range: KeyRange, reverse = false
): Future[Result[seq[KvRow], PersistencyError]] {.async.} =
  let r = (await KvScan.request(t.context, category, range, reverse)).valueOr:
    return err(liftErr(error))
  return ok(r.rows)

proc scanPrefix*(
    t: Job, category: string, prefix: Key, reverse = false
): Future[Result[seq[KvRow], PersistencyError]] {.async.} =
  let rng = prefixRange(prefix)
  let r = (await KvScan.request(t.context, category, rng, reverse)).valueOr:
    return err(liftErr(error))
  return ok(r.rows)

proc count*(
    t: Job, category: string, range: KeyRange
): Future[Result[int, PersistencyError]] {.async.} =
  let r = (await KvCount.request(t.context, category, range)).valueOr:
    return err(liftErr(error))
  return ok(r.n)

proc deleteAcked*(
    t: Job, category: string, key: Key
): Future[Result[bool, PersistencyError]] {.async.} =
  ## Goes through the read path so the caller learns whether a row was
  ## actually removed.
  let r = (await KvDelete.request(t.context, category, key)).valueOr:
    return err(liftErr(error))
  return ok(r.existed)

# ── Reads (async, typed errors) — string-lookup form ────────────────────

proc get*(
    p: Persistency, jobId: string, category: string, key: Key
): Future[Result[Option[seq[byte]], PersistencyError]] {.async.} =
  let j = ?p.job(jobId)
  return await j.get(category, key)

proc exists*(
    p: Persistency, jobId: string, category: string, key: Key
): Future[Result[bool, PersistencyError]] {.async.} =
  let j = ?p.job(jobId)
  return await j.exists(category, key)

proc scan*(
    p: Persistency, jobId: string, category: string, range: KeyRange, reverse = false
): Future[Result[seq[KvRow], PersistencyError]] {.async.} =
  let j = ?p.job(jobId)
  return await j.scan(category, range, reverse)

proc scanPrefix*(
    p: Persistency, jobId: string, category: string, prefix: Key, reverse = false
): Future[Result[seq[KvRow], PersistencyError]] {.async.} =
  let j = ?p.job(jobId)
  return await j.scanPrefix(category, prefix, reverse)

proc count*(
    p: Persistency, jobId: string, category: string, range: KeyRange
): Future[Result[int, PersistencyError]] {.async.} =
  let j = ?p.job(jobId)
  return await j.count(category, range)

proc deleteAcked*(
    p: Persistency, jobId: string, category: string, key: Key
): Future[Result[bool, PersistencyError]] {.async.} =
  let j = ?p.job(jobId)
  return await j.deleteAcked(category, key)

{.pop.}
