## Multi-Thread SignalBroker
## -------------------------
## Generates a multi-thread capable SignalBroker: a single handler registered
## on one thread (via `onSignal`), with `signal(...)` callable from any thread.
## Fire-and-forget — there is no reply path — but `signal` returns
## `Result[void, string]` so the caller learns whether the payload was
## *accepted* (a handler exists + the queue had room), never whether it ran.
##
## Same-thread signal→handler dispatch bypasses the ring and is delivered
## directly via `asyncSpawn`. Cross-thread delivery marshals the payload into a
## global refcounted slab cell and enqueues its index on the handler thread's
## Vyukov MPSC ring, then fires that thread's dispatch signal — identical
## machinery to the multi-thread EventBroker, minus the fan-out (a signal has
## exactly one target bucket per context).
##
## Structurally this is EventBroker(mt)'s fire-and-forget transport fused with
## RequestBroker(mt)'s single-registry ownership model:
##   - one bucket per (brokerCtx) — `onSignal` rejects a duplicate;
##   - the bucket-owning thread (the one that ran `onSignal`) allocates the
##     ring and, on `dropSignalHandler`, closes it; the poll fn hands the ring
##     to the per-thread pending-free registry, freed at `teardownBrokerThread`
##     (Invariant I0 — the owning thread is the only safe deallocator);
##   - the global payload slab is allocated lazily by the first
##     onSignal/signal caller, whose thread must outlive it (never freed,
##     like the EventBroker global slab).
##
## Lock-free caller fast-fail: a per-type `Atomic[int]` handler-present counter
## is bumped by `onSignal` / `dropSignalHandler`; `signal()` reads it with an
## acquire load and returns `"no signal handler installed"` with no lock taken
## when it is zero (no handler exists anywhere). A non-zero counter falls
## through to the locked bucket resolve, which pins the specific context.
## (The threadvar bucket-pointer cache described in the design is a further
## optimization deferred to a follow-up; correctness does not depend on it and
## the per-signal lock matches the shipped EventBroker(mt) emit path.)

{.push raises: [].}

import std/[macros, strutils, locks, atomics, options]
import chronos, chronicles
import results
import
  ./helper/broker_utils,
  ../broker_context,
  ./mt_broker_common,
  ./mt_queue,
  ./mt_codec,
  ./mt_config,
  ./broker_debug

export
  results, chronos, broker_context, chronicles, mt_broker_common, mt_config, options

# ---------------------------------------------------------------------------
# Macro code generator
# ---------------------------------------------------------------------------

proc generateMtSignalBroker*(
    body: NimNode, cfgIn: MtSigCfg = defaultMtSigCfg()
): NimNode =
  when defined(brokerDebug):
    echo body.treeRepr
    echo "SignalBroker mode: mt"

  let parsed = parseSingleTypeDef(body, "SignalBroker", collectFieldInfo = true)
  let typeIdent = parsed.typeIdent
  let objectDef = parsed.objectDef
  let fieldNames = parsed.fieldNames
  let fieldTypes = parsed.fieldTypes
  let hasInlineFields = parsed.hasInlineFields
  let isVoid = parsed.isVoid

  let exportedTypeIdent = postfix(copyNimTree(typeIdent), "*")
  let typeDisplayName = sanitizeIdentName(typeIdent)
  let typeNameLit = newLit(typeDisplayName)

  # Type-driven default for maxPayloadBytes (same policy as EventBroker(mt)):
  # a payload-less pulse or a scalar field collapses to the scalar bucket.
  var cfg = cfgIn
  if cfg.maxPayloadBytesOrigin == "default":
    if fieldTypes.len > 0:
      let cls = classifyFieldsMax(fieldTypes)
      cfg.maxPayloadBytes = cls.bytes
      cfg.maxPayloadBytesOrigin = "auto:" & cls.reason
      if cls.reason.startsWith("unclassifiable"):
        warning(
          "[brokers] SignalBroker(" & typeDisplayName & ") could not auto-size payload (" &
            cls.reason & "); falling back to " & $cls.bytes &
            " B. Override with `maxPayloadBytes = N`."
        )
    else:
      cfg.maxPayloadBytes = ScalarBytes
      cfg.maxPayloadBytesOrigin = "auto:void"

  when not defined(brokerConfigSilent):
    hint(fmtSigCfgSummary(typeDisplayName, cfg))

  # ── Identifier setup ──────────────────────────────────────────────────
  let handlerProcIdent = ident(typeDisplayName & "SignalHandler")
  let exportedHandlerProcIdent = postfix(copyNimTree(handlerProcIdent), "*")
  let bucketName = ident(typeDisplayName & "MtSignalBucket")

  let globalBucketsIdent = ident("g" & typeDisplayName & "MtSigBuckets")
  let globalBucketCountIdent = ident("g" & typeDisplayName & "MtSigBucketCount")
  let globalBucketCapIdent = ident("g" & typeDisplayName & "MtSigBucketCap")
  let globalLockIdent = ident("g" & typeDisplayName & "MtSigLock")
  let globalInitIdent = ident("g" & typeDisplayName & "MtSigInit")
  let globalSlabIdent = ident("g" & typeDisplayName & "MtSigSlab")
  let globalSlabInitIdent = ident("g" & typeDisplayName & "MtSigSlabInit")
  let presentIdent = ident("g" & typeDisplayName & "MtSigPresent")

  let initProcIdent = ident("ensureInit" & typeDisplayName & "MtSigBroker")
  let initSlabProcIdent = ident("ensureSlab" & typeDisplayName & "MtSigBroker")
  let growProcIdent = ident("grow" & typeDisplayName & "MtSigBuckets")
  let signalTaskIdent = ident("notify" & typeDisplayName & "Signal")
  let pollFnMakerIdent = ident("makePollFn" & typeDisplayName & "Sig")
  let releaseCellIdent = ident("releaseCell" & typeDisplayName & "Sig")
  let shardHintIdent = ident("shardHint" & typeDisplayName & "Sig")

  let marshalIdent = ident(typeDisplayName & "MtSigMarshal")
  let unmarshalIdent = ident(typeDisplayName & "MtSigUnmarshal")
  let marshalSizeIdent = ident($marshalIdent & "Size")

  let tvCtxIdent = ident("g" & typeDisplayName & "TvSigCtxs")
  let tvHandlerIdent = ident("g" & typeDisplayName & "TvSigHandlers")
  let tvFutsIdent = ident("g" & typeDisplayName & "TvSigFuts")

  let onSignalImplIdent = ident("onSignal" & typeDisplayName & "MtImpl")
  let signalImplIdent = ident("signal" & typeDisplayName & "MtImpl")
  let dropImplIdent = ident("drop" & typeDisplayName & "MtImpl")
  let setupBucketIdent = ident("setupBucket" & typeDisplayName & "Sig")
  let findHandlerIdent = ident("findTvHandler" & typeDisplayName & "Sig")

  let queueDepthLit = newLit(cfg.queueDepth)
  let slabCapacityLit = newLit(cfg.slabCapacity)
  let payloadBytesLit = newLit(cfg.maxPayloadBytes)
  let maxDynPayloadLit = newLit(cfg.maxDynamicPayloadBytes)
  let freeListShardsLit = newLit(uint32(cfg.freeListShards))

  result = newStmtList()

  # ── Type section ──────────────────────────────────────────────────────
  let handlerProcTy =
    if isVoid:
      quote:
        proc(): Future[void] {.async: (raises: []), gcsafe.}
    else:
      quote:
        proc(signalValue: `typeIdent`): Future[void] {.async: (raises: []), gcsafe.}

  result.add(
    quote do:
      type
        `exportedTypeIdent` = `objectDef`
        `exportedHandlerProcIdent` = `handlerProcTy`
        `bucketName` = object
          brokerCtx: BrokerContext
          ring: ptr VyukovMpscRing[uint32]
          handlerSignal: ptr BrokerSignalShared
          threadId: pointer
          threadGen: uint64 ## disambiguates reused threadvar addresses
          active: bool

  )

  # ── Codec procs (marshal / unmarshal / size of the payload value) ─────
  for procNode in genMtCodecProcs(marshalIdent, unmarshalIdent, typeIdent):
    result.add(procNode)

  # ── Global shared state ───────────────────────────────────────────────
  result.add(
    quote do:
      var `globalBucketsIdent`: ptr UncheckedArray[`bucketName`]
      var `globalBucketCountIdent`: int
      var `globalBucketCapIdent`: int
      var `globalLockIdent`: Lock
      var `globalInitIdent`: Atomic[int]
        ## 0 = uninitialised, 1 = initialising, 2 = ready.
      var `globalSlabIdent`: PayloadSlab
      var `globalSlabInitIdent`: Atomic[int]
      var `presentIdent`: Atomic[int]
        ## handler-present counter (# of installed handlers across all ctxs).
        ## `signal()` acquire-loads it; zero → fast-fail with no lock taken.
  )

  # ── Init helpers ──────────────────────────────────────────────────────
  result.add(
    quote do:
      proc `initSlabProcIdent`() =
        if `globalSlabInitIdent`.load(moRelaxed) == 2:
          return
        var expected = 0
        if `globalSlabInitIdent`.compareExchange(expected, 1, moAcquire, moRelaxed):
          initPayloadSlab(
            `globalSlabIdent`,
            capacity = uint32(`slabCapacityLit`),
            payloadBytes = uint32(`payloadBytesLit`),
            nShards = `freeListShardsLit`,
          )
          `globalSlabInitIdent`.store(2, moRelease)
        else:
          while `globalSlabInitIdent`.load(moAcquire) != 2:
            discard

      proc `initProcIdent`() =
        if `globalInitIdent`.load(moRelaxed) == 2:
          `initSlabProcIdent`()
          return
        var expected = 0
        if `globalInitIdent`.compareExchange(expected, 1, moAcquire, moRelaxed):
          initLock(`globalLockIdent`)
          `globalBucketCapIdent` = 4
          `globalBucketsIdent` = cast[ptr UncheckedArray[`bucketName`]](createShared(
            `bucketName`, `globalBucketCapIdent`
          ))
          `globalBucketCountIdent` = 0
          `globalInitIdent`.store(2, moRelease)
        else:
          while `globalInitIdent`.load(moAcquire) != 2:
            discard
        `initSlabProcIdent`()

      proc `growProcIdent`() =
        ## Must be called under lock.
        let newCap = `globalBucketCapIdent` * 2
        let newBuf =
          cast[ptr UncheckedArray[`bucketName`]](createShared(`bucketName`, newCap))
        for i in 0 ..< `globalBucketCountIdent`:
          newBuf[i] = `globalBucketsIdent`[i]
        # Intentional leak of the old buffer (see mt_event_broker.nim).
        `globalBucketsIdent` = newBuf
        `globalBucketCapIdent` = newCap

      proc `shardHintIdent`(): uint32 {.inline.} =
        cast[uint32](cast[uint](currentMtThreadId()) shr 4)

      proc `releaseCellIdent`(cellIdx: uint32) {.inline, gcsafe.} =
        if `globalSlabIdent`.decRefAndCheck(cellIdx):
          `globalSlabIdent`.release(cellIdx, `shardHintIdent`())

  )

  # ── Threadvar handler storage (owning thread) ─────────────────────────
  result.add(
    quote do:
      var `tvCtxIdent` {.threadvar.}: seq[BrokerContext]
      var `tvHandlerIdent` {.threadvar.}: seq[`handlerProcIdent`]
      var `tvFutsIdent` {.threadvar.}: seq[(BrokerContext, Future[void])]

      proc `findHandlerIdent`(brokerCtx: BrokerContext): `handlerProcIdent` =
        for i in 0 ..< `tvCtxIdent`.len:
          if `tvCtxIdent`[i] == brokerCtx:
            return `tvHandlerIdent`[i]
        default(`handlerProcIdent`)

  )

  # ── Dispatch task: swallow handler exceptions with a chronicles warn ──
  # Always takes the payload value so the same-thread and cross-thread dispatch
  # call sites stay uniform; the void form simply ignores it (its handler takes
  # no arg). `signalValue` is the wire value in both cases (a default-
  # constructed empty object for the void pulse). The `when` selects the arity
  # at generation time; the dead branch is parsed but never sem-checked.
  let isVoidLit = newLit(isVoid)
  result.add(
    quote do:
      proc `signalTaskIdent`(
          callback: `handlerProcIdent`, signalValue: `typeIdent`
      ): Future[void] {.async: (raises: []).} =
        if callback.isNil():
          return
        try:
          when `isVoidLit`:
            await callback()
          else:
            await callback(signalValue)
        except CatchableError:
          warn "SignalBroker handler raised",
            signalType = `typeNameLit`, error = getCurrentExceptionMsg()

  )

  # ── Poll fn maker (handler-thread side) ───────────────────────────────
  result.add(
    quote do:
      proc `pollFnMakerIdent`(
          ring: ptr VyukovMpscRing[uint32], loopCtx: BrokerContext
      ): ThreadDispatchPollFn =
        let capturedRing = ring
        let capturedCtx = loopCtx
        return proc(): int {.gcsafe, raises: [].} =
          {.cast(gcsafe).}:
            var cellIdx: uint32
            if not capturedRing.tryDequeue(cellIdx):
              if capturedRing.isClosed():
                # Owner-thread deferred free (global slab + no pool → nil, nil).
                enqueuePendingRingFree(capturedRing, nil, nil)
                return 2
              return 0
            var ev: `typeIdent`
            let payloadPtr = `globalSlabIdent`.dataPtr(cellIdx)
            let payloadLen = `globalSlabIdent`.dataLen(cellIdx)
            let ok =
              try:
                `unmarshalIdent`(payloadPtr, payloadLen, ev)
              except Exception:
                false
            if ok:
              let handler = `findHandlerIdent`(capturedCtx)
              if not handler.isNil:
                let fut: Future[void] = `signalTaskIdent`(handler, ev)
                `tvFutsIdent`.add((capturedCtx, fut))
                asyncSpawn fut
            else:
              error "Failed to unmarshal signal payload", signalType = `typeNameLit`
            `releaseCellIdent`(cellIdx)
            return 1

  )

  # ── setupBucket (owning thread; allocates ring, registers poller) ─────
  result.add(
    quote do:
      proc `setupBucketIdent`(
          brokerCtx: BrokerContext
      ): Result[ptr VyukovMpscRing[uint32], string] =
        let myThreadId = currentMtThreadId()
        let myThreadGen = currentMtThreadGen()
        var ring: ptr VyukovMpscRing[uint32]
        withLock(`globalLockIdent`):
          for i in 0 ..< `globalBucketCountIdent`:
            if `globalBucketsIdent`[i].brokerCtx == brokerCtx and
                `globalBucketsIdent`[i].active:
              return err("SignalBroker(" & `typeNameLit` & "): handler already set")
          if `globalBucketCountIdent` >= `globalBucketCapIdent`:
            `growProcIdent`()
          ring = newVyukovMpscRing[uint32](`queueDepthLit`)
          let handlerSig = getOrInitBrokerSignal()
          let idx = `globalBucketCountIdent`
          `globalBucketsIdent`[idx] = `bucketName`(
            brokerCtx: brokerCtx,
            ring: ring,
            handlerSignal: handlerSig,
            threadId: myThreadId,
            threadGen: myThreadGen,
            active: true,
          )
          `globalBucketCountIdent` += 1
        registerBrokerPoller(`pollFnMakerIdent`(ring, brokerCtx))
        ensureBrokerDispatchStarted()
        ok(ring)

  )

  # ── onSignal impl ─────────────────────────────────────────────────────
  result.add(
    quote do:
      proc `onSignalImplIdent`(
          brokerCtx: BrokerContext, handler: `handlerProcIdent`
      ): Result[void, string] =
        if handler.isNil():
          return err("SignalBroker(" & `typeNameLit` & "): handler must be non-nil")
        `initProcIdent`()
        let r = `setupBucketIdent`(brokerCtx)
        if r.isErr():
          return err(r.error)
        `tvCtxIdent`.add(brokerCtx)
        `tvHandlerIdent`.add(handler)
        discard `presentIdent`.fetchAdd(1, moRelease)
        ok()

  )

  # ── signal impl (accept-and-dispatch; caller's thread) ────────────────
  # Always carries a payload value on the wire; the void form passes an empty
  # `default(T)` and the dispatch drops it (handler takes no arg).
  result.add(
    quote do:
      proc `signalImplIdent`(
          brokerCtx: BrokerContext, signalValue: `typeIdent`
      ): Result[void, string] {.gcsafe.} =
        # Lock-free fast-fail: no handler installed anywhere.
        if `presentIdent`.load(moAcquire) == 0:
          return err("no signal handler installed")
        `initProcIdent`()

        var ring: ptr VyukovMpscRing[uint32]
        var handlerSig: ptr BrokerSignalShared
        var sameThread = false
        var found = false
        let myThreadId = currentMtThreadId()
        let myThreadGen = currentMtThreadGen()
        withLock(`globalLockIdent`):
          for i in 0 ..< `globalBucketCountIdent`:
            if `globalBucketsIdent`[i].brokerCtx == brokerCtx and
                `globalBucketsIdent`[i].active:
              found = true
              if `globalBucketsIdent`[i].threadId == myThreadId and
                  `globalBucketsIdent`[i].threadGen == myThreadGen:
                sameThread = true
              else:
                ring = `globalBucketsIdent`[i].ring
                handlerSig = `globalBucketsIdent`[i].handlerSignal
              break

        if not found:
          return err("no signal handler installed")

        # Same-thread fast path: bypass the ring, dispatch directly.
        if sameThread:
          let handler = `findHandlerIdent`(brokerCtx)
          if handler.isNil:
            return err("no signal handler installed")
          {.cast(gcsafe).}:
            let fut: Future[void] = `signalTaskIdent`(handler, signalValue)
            `tvFutsIdent`.add((brokerCtx, fut))
            asyncSpawn fut
          return ok()

        # Cross-thread: marshal payload into a refcounted global slab cell,
        # enqueue its index on the handler thread's ring, wake that thread.
        let shardHint = `shardHintIdent`()
        let cellIdx = `globalSlabIdent`.claim(shardHint)
        if cellIdx == EmptyIdx:
          return err("queue full")
        let cell = `globalSlabIdent`.cellPtr(cellIdx)
        let payloadPtr = `globalSlabIdent`.cellPayloadPtr(cellIdx)
        let written =
          try:
            `marshalIdent`(
              payloadPtr, int(`globalSlabIdent`.cellPayloadCap), signalValue
            )
          except Exception:
            -1
        if written >= 0:
          cell.payloadSize = uint32(written)
        else:
          let needed =
            try:
              `marshalSizeIdent`(signalValue)
            except Exception:
              -1
          if needed < 0 or needed > `maxDynPayloadLit`:
            `globalSlabIdent`.release(cellIdx, shardHint)
            return err(
              "SignalBroker(" & `typeNameLit` &
                "): payload exceeds maxDynamicPayloadBytes"
            )
          let spillBuf = allocShared0(needed)
          if spillBuf.isNil:
            `globalSlabIdent`.release(cellIdx, shardHint)
            return err("SignalBroker(" & `typeNameLit` & "): spill allocation failed")
          let w2 =
            try:
              `marshalIdent`(
                cast[ptr UncheckedArray[byte]](spillBuf), needed, signalValue
              )
            except Exception:
              -1
          if w2 < 0:
            deallocShared(spillBuf)
            `globalSlabIdent`.release(cellIdx, shardHint)
            return err("SignalBroker(" & `typeNameLit` & "): payload marshal failed")
          `globalSlabIdent`.setOverflow(cellIdx, spillBuf, uint32(w2))
        cell.refcount.store(1, moRelease)
        if not ring.tryEnqueue(cellIdx):
          `releaseCellIdent`(cellIdx)
          return err("queue full")
        fireBrokerSignal(handlerSig)
        ok()

  )

  # ── dropSignalHandler impl (suspension-free; mirrors clearProvider) ───
  # NO async / NO await — the public overload is async only for cross-lane
  # shape parity. Removes the bucket, closes the ring (poll fn hands it to the
  # per-thread pending-free registry, freed at teardownBrokerThread), cleans
  # the owning thread's threadvar, and decrements the handler-present counter.
  result.add(
    quote do:
      proc `dropImplIdent`(brokerCtx: BrokerContext) {.gcsafe.} =
        `initProcIdent`()
        var ring: ptr VyukovMpscRing[uint32]
        var handlerSig: ptr BrokerSignalShared
        var isOwner = false
        var found = false
        let myThreadId = currentMtThreadId()
        let myThreadGen = currentMtThreadGen()
        withLock(`globalLockIdent`):
          var foundIdx = -1
          for i in 0 ..< `globalBucketCountIdent`:
            if `globalBucketsIdent`[i].brokerCtx == brokerCtx and
                `globalBucketsIdent`[i].active:
              ring = `globalBucketsIdent`[i].ring
              handlerSig = `globalBucketsIdent`[i].handlerSignal
              isOwner = (
                `globalBucketsIdent`[i].threadId == myThreadId and
                `globalBucketsIdent`[i].threadGen == myThreadGen
              )
              foundIdx = i
              found = true
              break
          if foundIdx >= 0:
            for j in foundIdx ..< `globalBucketCountIdent` - 1:
              `globalBucketsIdent`[j] = `globalBucketsIdent`[j + 1]
            `globalBucketCountIdent` -= 1

        if not found:
          return

        if isOwner:
          {.cast(gcsafe).}:
            for i in countdown(`tvCtxIdent`.len - 1, 0):
              if `tvCtxIdent`[i] == brokerCtx:
                `tvCtxIdent`.del(i)
                `tvHandlerIdent`.del(i)
                break
        discard `presentIdent`.fetchSub(1, moRelease)
        if not ring.isNil:
          ring.close()
          fireBrokerSignal(handlerSig)

  )

  # ── Public onSignal ───────────────────────────────────────────────────
  result.add(
    quote do:
      proc onSignal*(
          _: typedesc[`typeIdent`], handler: `handlerProcIdent`
      ): Result[void, string] =
        `onSignalImplIdent`(DefaultBrokerContext, handler)

      proc onSignal*(
          _: typedesc[`typeIdent`],
          brokerCtx: BrokerContext,
          handler: `handlerProcIdent`,
      ): Result[void, string] =
        `onSignalImplIdent`(brokerCtx, handler)

  )

  # ── Public signal ─────────────────────────────────────────────────────
  if isVoid:
    result.add(
      quote do:
        proc signal*(
            _: typedesc[`typeIdent`], brokerCtx: BrokerContext
        ): Result[void, string] =
          `signalImplIdent`(brokerCtx, `typeIdent`())

        proc signal*(_: typedesc[`typeIdent`]): Result[void, string] =
          `signalImplIdent`(DefaultBrokerContext, `typeIdent`())

    )
  else:
    result.add(
      quote do:
        proc signal*(
            _: typedesc[`typeIdent`], brokerCtx: BrokerContext, signalValue: `typeIdent`
        ): Result[void, string] =
          `signalImplIdent`(brokerCtx, signalValue)

        proc signal*(
            _: typedesc[`typeIdent`], signalValue: `typeIdent`
        ): Result[void, string] =
          `signalImplIdent`(DefaultBrokerContext, signalValue)

        proc signal*(signalValue: `typeIdent`): Result[void, string] =
          `signalImplIdent`(DefaultBrokerContext, signalValue)

    )

  # ── Field-constructor signal overloads (inline object types) ──────────
  if hasInlineFields:
    let typedescParamType =
      newTree(nnkBracketExpr, ident("typedesc"), copyNimTree(typeIdent))
    let resultTy = quote:
      Result[void, string]

    var emitCtorExpr = newTree(nnkObjConstr, copyNimTree(typeIdent))
    for i in 0 ..< fieldNames.len:
      emitCtorExpr.add(
        newTree(
          nnkExprColonExpr, copyNimTree(fieldNames[i]), copyNimTree(fieldNames[i])
        )
      )

    block:
      var params = newTree(nnkFormalParams, copyNimTree(resultTy))
      params.add(newTree(nnkIdentDefs, ident("_"), typedescParamType, newEmptyNode()))
      for i in 0 ..< fieldNames.len:
        params.add(
          newTree(
            nnkIdentDefs,
            copyNimTree(fieldNames[i]),
            copyNimTree(fieldTypes[i]),
            newEmptyNode(),
          )
        )
      let callDefault = newCall(
        copyNimTree(signalImplIdent),
        ident("DefaultBrokerContext"),
        copyNimTree(emitCtorExpr),
      )
      result.add(
        newTree(
          nnkProcDef,
          postfix(ident("signal"), "*"),
          newEmptyNode(),
          newEmptyNode(),
          params,
          newEmptyNode(),
          newEmptyNode(),
          newStmtList(callDefault),
        )
      )

    block:
      var params = newTree(nnkFormalParams, copyNimTree(resultTy))
      params.add(newTree(nnkIdentDefs, ident("_"), typedescParamType, newEmptyNode()))
      params.add(
        newTree(
          nnkIdentDefs, ident("brokerCtx"), ident("BrokerContext"), newEmptyNode()
        )
      )
      for i in 0 ..< fieldNames.len:
        params.add(
          newTree(
            nnkIdentDefs,
            copyNimTree(fieldNames[i]),
            copyNimTree(fieldTypes[i]),
            newEmptyNode(),
          )
        )
      let callCtx = newCall(
        copyNimTree(signalImplIdent), ident("brokerCtx"), copyNimTree(emitCtorExpr)
      )
      result.add(
        newTree(
          nnkProcDef,
          postfix(ident("signal"), "*"),
          newEmptyNode(),
          newEmptyNode(),
          params,
          newEmptyNode(),
          newEmptyNode(),
          newStmtList(callCtx),
        )
      )

  # ── dropSignalHandler / hasSignalHandler ──────────────────────────────
  # Public drop is async for cross-lane parity; the impl is suspension-free so
  # a discarded Future still clears eagerly (same contract as dropListener).
  result.add(
    quote do:
      proc dropSignalHandler*(
          _: typedesc[`typeIdent`], brokerCtx: BrokerContext
      ): Future[void] {.async: (raises: []).} =
        `dropImplIdent`(brokerCtx)

      proc dropSignalHandler*(
          _: typedesc[`typeIdent`]
      ): Future[void] {.async: (raises: []).} =
        `dropImplIdent`(DefaultBrokerContext)

      proc hasSignalHandler*(_: typedesc[`typeIdent`], brokerCtx: BrokerContext): bool =
        `initProcIdent`()
        withLock(`globalLockIdent`):
          for i in 0 ..< `globalBucketCountIdent`:
            if `globalBucketsIdent`[i].brokerCtx == brokerCtx and
                `globalBucketsIdent`[i].active:
              return true
        false

      proc hasSignalHandler*(_: typedesc[`typeIdent`]): bool =
        hasSignalHandler(`typeIdent`, DefaultBrokerContext)

      proc signalHandlerPresent*(_: typedesc[`typeIdent`]): bool {.gcsafe.} =
        ## Lock-free acquire-load of the handler-present counter — safe to call
        ## from any thread (used by the FFI `<lib>_call` slot-free signal path to
        ## fast-fail with ProviderErr before the cross-thread hop). Coarse: true
        ## means a handler exists for *some* context (the FFI lane installs a
        ## single handler on the processing thread, so this is exact there).
        `presentIdent`.load(moAcquire) != 0

  )

  # ── Mock/replace trio (owning thread only) ────────────────────────────
  # Reads/writes the per-thread threadvar handler slot, so it MUST run on the
  # thread that installed the handler. `replaceSignalHandler` swaps only the
  # local closure — the bucket/ring/present-counter are untouched (no window
  # where `signal()` errs), ideal for feature toggles. Replace-with-`default`
  # does NOT tear the bucket down; use `dropSignalHandler` to fully remove.
  result.add(
    quote do:
      proc getCurrentSignalHandler*(
          _: typedesc[`typeIdent`], brokerCtx: BrokerContext
      ): Option[`handlerProcIdent`] =
        let h = `findHandlerIdent`(brokerCtx)
        if h.isNil:
          none(`handlerProcIdent`)
        else:
          some(h)

      proc replaceSignalHandler*(
          _: typedesc[`typeIdent`],
          brokerCtx: BrokerContext,
          handler: `handlerProcIdent`,
      ): Result[void, string] =
        ## Owning-thread only. Replace-or-insert the local closure; a new ctx
        ## also sets up its bucket + bumps the present counter.
        `initProcIdent`()
        for i in 0 ..< `tvCtxIdent`.len:
          if `tvCtxIdent`[i] == brokerCtx:
            `tvHandlerIdent`[i] = handler
            return ok()
        let r = `setupBucketIdent`(brokerCtx)
        if r.isErr():
          return err(r.error)
        `tvCtxIdent`.add(brokerCtx)
        `tvHandlerIdent`.add(handler)
        discard `presentIdent`.fetchAdd(1, moRelease)
        ok()

      template withMockSignalHandler*(
          t: typedesc[`typeIdent`],
          brokerCtx: BrokerContext,
          mock: `handlerProcIdent`,
          body: untyped,
      ): untyped =
        ## Owning-thread only. Install `mock` for the duration of `body`, then
        ## restore the captured handler (or drop it if none was set).
        let savedMockSignalHandler = getCurrentSignalHandler(t, brokerCtx)
        discard replaceSignalHandler(t, brokerCtx, mock)
        try:
          body
        finally:
          if savedMockSignalHandler.isSome:
            discard replaceSignalHandler(t, brokerCtx, savedMockSignalHandler.get)
          else:
            discard dropSignalHandler(t, brokerCtx)

  )

  # ── bind / rebind signal-handler sugar (issue #42) ────────────────
  # `bindSignalHandler` = sugar for `onSignal`, `rebindSignalHandler` = sugar for
  # `replaceSignalHandler` (owning-thread only, same as the verbs they wrap).
  block:
    var slot = BindSlot(returnType: futureVoidTy(), pragma: procTyPragma(handlerProcTy))
    if isVoid:
      slot.params = @[]
    else:
      slot.params = @[
        newTree(
          nnkIdentDefs, ident("signalValue"), copyNimTree(typeIdent), newEmptyNode()
        )
      ]
    result.add(
      buildBindTemplates(
        typeIdent, "onSignal", "bindSignalHandler", @[slot], awaitCall = true
      )
    )
    result.add(
      buildBindTemplates(
        typeIdent,
        "replaceSignalHandler",
        "rebindSignalHandler",
        @[slot],
        awaitCall = true,
      )
    )

  when defined(brokerDebug):
    writeBrokerDebug("SignalBrokerMt", typeDisplayName, result)
    when defined(brokerDebugStdout):
      echo result.repr

  return result

{.pop.}
