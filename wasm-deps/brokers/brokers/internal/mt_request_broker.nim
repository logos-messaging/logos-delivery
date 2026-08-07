## Multi-Thread RequestBroker
## --------------------------
## Generates a multi-thread capable RequestBroker where the provider runs
## on the thread that called `setProvider` (which must keep its chronos
## event loop running), and requests from other threads are routed via
## a lock-free Vyukov MPSC ring + per-bucket payload slab + response slot
## pool.
##
## Same-thread requests bypass the ring and call the provider directly.
##
## See `doc/REFACTOR_MT_QUEUE.md` for the full design; this file is the
## RequestBroker integration of Phase 4 of that plan.
##
## §2.6 safety contract honored by construction (Invariant I0):
##   - The bucket-owning thread (the provider thread, the one that
##     called `setProvider`) allocates its ring + request slab +
##     response slot pool via `createShared`, and frees them via
##     `clearProvider` on the same thread.
##   - Sender threads only ever touch atomics + memcpy + signal-fire on
##     the hot path — never the Nim allocator beyond `claim`/`release`
##     of pre-allocated slab cells and response slots.

{.push raises: [].}

import std/[macros, strutils, locks, os, atomics, options]
import chronos, chronicles
import results
import ./helper/broker_utils, ../broker_context

import ./mt_broker_common, ./mt_queue, ./mt_codec, ./mt_config
import ./broker_debug
export
  results, chronos, chronicles, broker_context, mt_broker_common, mt_config, options
# The generated provideIt/reprovideIt templates expand `providerBody` at the
# user's call site, so the checker macro must be visible there.
export providerBody

# Capacity defaults moved to `mt_config.nim` and re-exported via the
# `mt_config` module so existing references to `DefaultMtReq*` constants
# continue to resolve.

# ---------------------------------------------------------------------------
# Macro code generator
# ---------------------------------------------------------------------------

proc isAsyncReturnTypeValid(returnType, typeIdent: NimNode): bool =
  if returnType.kind != nnkBracketExpr or returnType.len != 2:
    return false
  if returnType[0].kind != nnkIdent or not returnType[0].eqIdent("Future"):
    return false
  let inner = returnType[1]
  if inner.kind != nnkBracketExpr or inner.len != 3:
    return false
  if inner[0].kind != nnkIdent or not inner[0].eqIdent("Result"):
    return false
  if inner[1].kind != nnkIdent or not inner[1].eqIdent($typeIdent):
    return false
  inner[2].kind == nnkIdent and inner[2].eqIdent("string")

proc generateMtRequestBroker*(
    body: NimNode, cfgIn: MtReqCfg = defaultMtReqCfg()
): NimNode =
  when defined(brokerDebug):
    echo body.treeRepr
    echo "RequestBroker mode: mt"

  # Classify legacy (`proc signature*`) vs proc-sugar (lowercase verb procs).
  # Mirrors request_broker.nim; MT is always async.
  var hasSignatureProc = false
  var hasOtherProc = false
  for stmt in body:
    if stmt.kind == nnkProcDef:
      let nm = stmt[0]
      let nmId = (if nm.kind == nnkPostfix: nm[1] else: nm)
      if ($nmId).startsWith("signature"):
        hasSignatureProc = true
      else:
        hasOtherProc = true
  let isSugar = hasOtherProc and not hasSignatureProc

  var typeIdent: NimNode = nil
  var objectDef: NimNode = nil
  var payloadType: NimNode = nil
  var responseFieldTypes: seq[NimNode] = @[]
  var zeroArgSig: NimNode = nil
  var zeroArgProviderName: NimNode = nil
  var argSig: NimNode = nil
  var argParams: seq[NimNode] = @[]
  var argProviderName: NimNode = nil

  if not isSugar:
    let parsed = parseSingleTypeDef(
      body, "RequestBroker", allowRefToNonObject = true, collectFieldInfo = true
    )
    typeIdent = parsed.typeIdent
    objectDef = parsed.objectDef
    responseFieldTypes = parsed.fieldTypes
    payloadType = copyNimTree(typeIdent) # legacy: dispatch tag == payload

    for stmt in body:
      case stmt.kind
      of nnkProcDef:
        let procName = stmt[0]
        let procNameIdent =
          case procName.kind
          of nnkIdent:
            procName
          of nnkPostfix:
            procName[1]
          else:
            procName
        if not ($procNameIdent).startsWith("signature"):
          error("Signature proc names must start with `signature`", procName)
        let params = stmt.params
        if params.len == 0:
          error("Signature must declare a return type", stmt)
        let returnType = params[0]
        if not isAsyncReturnTypeValid(returnType, typeIdent):
          error(
            "MT RequestBroker signature must return Future[Result[`" & $typeIdent &
              "`, string]]",
            stmt,
          )
        let paramCount = params.len - 1
        if paramCount == 0:
          if zeroArgSig != nil:
            error("Only one zero-argument signature is allowed", stmt)
          zeroArgSig = stmt
          zeroArgProviderName = ident(sanitizeIdentName(typeIdent) & "ProviderNoArgs")
        elif paramCount >= 1:
          if argSig != nil:
            error("Only one argument-based signature is allowed", stmt)
          argSig = stmt
          argParams = @[]
          for idx in 1 ..< params.len:
            let paramDef = params[idx]
            if paramDef.kind != nnkIdentDefs:
              error(
                "Signature parameter must be a standard identifier declaration",
                paramDef,
              )
            let paramTypeNode = paramDef[paramDef.len - 2]
            if paramTypeNode.kind == nnkEmpty:
              error("Signature parameter must declare a type", paramDef)
            argParams.add(copyNimTree(paramDef))
          argProviderName = ident(sanitizeIdentName(typeIdent) & "ProviderWithArgs")
      of nnkTypeSection, nnkEmpty:
        discard
      else:
        error("Unsupported statement inside RequestBroker definition", stmt)

    if zeroArgSig.isNil() and argSig.isNil():
      zeroArgSig = newEmptyNode()
      zeroArgProviderName = ident(sanitizeIdentName(typeIdent) & "ProviderNoArgs")
  else:
    # ---- New proc-sugar form (option B / decoupled payload) ----
    let sg = parseRequestSugar(body, "RequestBroker", async = true)
    typeIdent = sg.typeIdent
    objectDef = sg.objectDef
    payloadType = sg.payloadType
    responseFieldTypes = sg.fieldTypes
    if not sg.zeroArgProc.isNil:
      zeroArgSig = sg.zeroArgProc
      zeroArgProviderName = ident(sanitizeIdentName(typeIdent) & "ProviderNoArgs")
    if not sg.argProc.isNil:
      argSig = sg.argProc
      argParams = sg.argParams
      argProviderName = ident(sanitizeIdentName(typeIdent) & "ProviderWithArgs")

  let exportedTypeIdent = postfix(copyNimTree(typeIdent), "*")
  let typeDisplayName = sanitizeIdentName(typeIdent)
  let typeNameLit = newLit(typeDisplayName)

  let returnType = quote:
    Future[Result[`payloadType`, string]]

  # ── Type-driven auto-defaults ───────────────────────────────────────
  # Void / zero-field response and zero-arg signatures collapse to the
  # scalar bucket: nothing larger than the Result envelope's tag bytes
  # ever traverses the wire. Leaving the conservative 64 KB response /
  # 1 KB payload default in place would otherwise pin a 16 MB response
  # pool per RequestBroker for what is effectively a notification.
  var cfg = cfgIn
  if cfg.maxResponseBytesOrigin == "default":
    if responseFieldTypes.len > 0:
      let cls = classifyFieldsMax(responseFieldTypes)
      cfg.maxResponseBytes = cls.bytes
      cfg.maxResponseBytesOrigin = "auto:" & cls.reason
      if cls.reason.startsWith("unclassifiable"):
        warning(
          "[brokers] RequestBroker(" & typeDisplayName &
            ") could not auto-size response (" & cls.reason & "); falling back to " &
            $cls.bytes & " B. Override with `maxResponseBytes = N`."
        )
    else:
      cfg.maxResponseBytes = ScalarBytes
      cfg.maxResponseBytesOrigin = "auto:void"
  if cfg.maxPayloadBytesOrigin == "default":
    if argParams.len > 0:
      var argTypes = newSeqOfCap[NimNode](argParams.len)
      for p in argParams:
        argTypes.add(p[p.len - 2])
      let cls = classifyFieldsMax(argTypes)
      cfg.maxPayloadBytes = cls.bytes
      cfg.maxPayloadBytesOrigin = "auto:" & cls.reason
      if cls.reason.startsWith("unclassifiable"):
        warning(
          "[brokers] RequestBroker(" & typeDisplayName &
            ") could not auto-size request payload (" & cls.reason &
            "); falling back to " & $cls.bytes &
            " B. Override with `maxPayloadBytes = N`."
        )
    else:
      cfg.maxPayloadBytes = ScalarBytes
      cfg.maxPayloadBytesOrigin = "auto:void"

  when not defined(brokerConfigSilent):
    hint(fmtReqCfgSummary(typeDisplayName, cfg))

  # ── Identifier setup ────────────────────────────────────────────────
  let requestMsgName = ident(typeDisplayName & "MtRequestMsg")
  let bucketName = ident(typeDisplayName & "MtBucket")

  let globalBucketsIdent = ident("g" & typeDisplayName & "MtBuckets")
  let globalBucketCountIdent = ident("g" & typeDisplayName & "MtBucketCount")
  let globalBucketCapIdent = ident("g" & typeDisplayName & "MtBucketCap")
  let globalLockIdent = ident("g" & typeDisplayName & "MtLock")
  let globalInitIdent = ident("g" & typeDisplayName & "MtInit")
  let timeoutVarIdent = ident("g" & typeDisplayName & "MtTimeout")

  let initProcIdent = ident("ensureInit" & typeDisplayName & "MtBroker")
  let growProcIdent = ident("grow" & typeDisplayName & "MtBuckets")
  let sendReplyIdent = ident("sendReply" & typeDisplayName)
  let handleMsgIdent = ident("handleMsg" & typeDisplayName)
  let pollFnMakerIdent = ident("makePollFn" & typeDisplayName)
  let shardHintIdent = ident("shardHint" & typeDisplayName)
  let marshalIdent = ident(typeDisplayName & "MtMarshal")
  let unmarshalIdent = ident(typeDisplayName & "MtUnmarshal")
  let marshalSizeIdent = ident(typeDisplayName & "MtMarshalSize")
  let marshalRespIdent = ident(typeDisplayName & "MtMarshalResp")
  let unmarshalRespIdent = ident(typeDisplayName & "MtUnmarshalResp")
  let marshalRespSizeIdent = ident(typeDisplayName & "MtMarshalRespSize")

  let queueDepthLit = newLit(cfg.queueDepth)
  let slabCapacityLit = newLit(cfg.slabCapacity)
  let payloadBytesLit = newLit(cfg.maxPayloadBytes)
  let maxDynPayloadLit = newLit(cfg.maxDynamicPayloadBytes)
  let responseSlotsLit = newLit(cfg.responseSlots)
  let responseBytesLit = newLit(cfg.maxResponseBytes)
  let freeListShardsLit = newLit(uint32(cfg.freeListShards))

  result = newStmtList()

  # ── Type section (typeIdent + provider proc types) ───────────────────
  var typeSection = newTree(nnkTypeSection)
  typeSection.add(newTree(nnkTypeDef, exportedTypeIdent, newEmptyNode(), objectDef))

  proc makeProcType(returnType: NimNode, params: seq[NimNode]): NimNode =
    var formal = newTree(nnkFormalParams)
    formal.add(returnType)
    for param in params:
      formal.add(param)
    let pragmas = newTree(nnkPragma, ident("async"))
    newTree(nnkProcTy, formal, pragmas)

  if not zeroArgSig.isNil():
    let procType = makeProcType(returnType, @[])
    typeSection.add(newTree(nnkTypeDef, zeroArgProviderName, newEmptyNode(), procType))
  if not argSig.isNil():
    let procType = makeProcType(returnType, cloneParams(argParams))
    typeSection.add(newTree(nnkTypeDef, argProviderName, newEmptyNode(), procType))

  # Request message struct. Carries args inline plus a response-slot
  # index (the per-bucket pool index where the provider writes the
  # result) and the requester's signal pointer (so the provider can
  # wake the requester's dispatcher after writing).
  var msgRecList = newTree(nnkRecList)
  msgRecList.add(
    newTree(nnkIdentDefs, ident("requestKind"), ident("int"), newEmptyNode())
  )
  if not argSig.isNil():
    for paramDef in argParams:
      for i in 0 ..< paramDef.len - 2:
        let nameNode = paramDef[i]
        if nameNode.kind != nnkEmpty:
          let typeNode = paramDef[paramDef.len - 2]
          msgRecList.add(
            newTree(
              nnkIdentDefs, ident($nameNode), copyNimTree(typeNode), newEmptyNode()
            )
          )
  msgRecList.add(
    newTree(nnkIdentDefs, ident("responseSlotIdx"), ident("uint32"), newEmptyNode())
  )
  msgRecList.add(
    newTree(
      nnkIdentDefs,
      ident("requesterSignal"),
      newTree(nnkPtrTy, ident("BrokerSignalShared")),
      newEmptyNode(),
    )
  )
  typeSection.add(
    newTree(
      nnkTypeDef,
      requestMsgName,
      newEmptyNode(),
      newTree(nnkObjectTy, newEmptyNode(), newEmptyNode(), msgRecList),
    )
  )

  # Bucket struct.
  let responseSlotPoolType = quote:
    ptr ResponseSlotPool
  let requestRingType = quote:
    ptr VyukovMpscRing[uint32]
  let requestSlabType = quote:
    ptr PayloadSlab

  var bucketRecList = newTree(nnkRecList)
  bucketRecList.add(
    newTree(nnkIdentDefs, ident("brokerCtx"), ident("BrokerContext"), newEmptyNode())
  )
  bucketRecList.add(
    newTree(nnkIdentDefs, ident("ring"), requestRingType, newEmptyNode())
  )
  bucketRecList.add(
    newTree(nnkIdentDefs, ident("slab"), requestSlabType, newEmptyNode())
  )
  bucketRecList.add(
    newTree(
      nnkIdentDefs, ident("responseSlotPool"), responseSlotPoolType, newEmptyNode()
    )
  )
  bucketRecList.add(
    newTree(
      nnkIdentDefs,
      ident("providerSignal"),
      newTree(nnkPtrTy, ident("BrokerSignalShared")),
      newEmptyNode(),
    )
  )
  bucketRecList.add(
    newTree(nnkIdentDefs, ident("threadId"), ident("pointer"), newEmptyNode())
  )
  bucketRecList.add(
    newTree(nnkIdentDefs, ident("threadGen"), ident("uint64"), newEmptyNode())
  )
  typeSection.add(
    newTree(
      nnkTypeDef,
      bucketName,
      newEmptyNode(),
      newTree(nnkObjectTy, newEmptyNode(), newEmptyNode(), bucketRecList),
    )
  )

  result.add(typeSection)

  # ── Codec procs for ReqMsg ───────────────────────────────────────────
  for procNode in genMtCodecProcs(marshalIdent, unmarshalIdent, requestMsgName):
    result.add(procNode)

  # ── Codec procs for Result[typeIdent, string] ───────────────────────
  # Custom — `Result` is a case object on `oResultPrivate`; the generic
  # `fieldPairs`-based marshaler would touch the wrong-tag fields. We
  # encode an explicit `isOk` byte followed by either the value (T) or
  # the error (string), recursively via mtMarshalValue/Unmarshal.
  result.add(
    quote do:
      proc `marshalRespIdent`(
          buf: ptr UncheckedArray[byte], cap: int, res: Result[`payloadType`, string]
      ): int {.gcsafe, raises: [].} =
        var pos = 0
        if pos + 1 > cap:
          return -1
        let isOk = byte(if res.isOk: 1 else: 0)
        buf[pos] = isOk
        pos += 1
        if res.isOk:
          when not (`payloadType` is void):
            let val = res.value
            if not mtMarshalValue(buf, cap, val, pos):
              return -1
        else:
          let errMsg = res.error
          if not mtMarshalValue(buf, cap, errMsg, pos):
            return -1
        return pos

      proc `unmarshalRespIdent`(
          buf: ptr UncheckedArray[byte],
          len: int,
          dst: var Result[`payloadType`, string],
      ): bool {.gcsafe, raises: [].} =
        var pos = 0
        if pos + 1 > len:
          return false
        let isOk = buf[pos]
        pos += 1
        if isOk == 1'u8:
          when (`payloadType` is void):
            dst.ok()
          else:
            var val: `payloadType`
            if not mtUnmarshalValue(buf, len, val, pos):
              return false
            dst = ok(Result[`payloadType`, string], val)
        else:
          var errMsg: string
          if not mtUnmarshalValue(buf, len, errMsg, pos):
            return false
          dst = err(Result[`payloadType`, string], errMsg)
        return true

      proc `marshalRespSizeIdent`(
          res: Result[`payloadType`, string]
      ): int {.gcsafe, raises: [].} =
        ## Exact marshaled byte length of a response — mirrors `marshalRespIdent`
        ## (1 isOk byte + value-or-error). Used to size a heap-spill buffer.
        result = 1
        if res.isOk:
          when not (`payloadType` is void):
            result += mtMarshalSizeValue(res.value)
        else:
          result += mtMarshalSizeValue(res.error)

  )

  # ── Global state ────────────────────────────────────────────────────
  result.add(
    quote do:
      var `globalBucketsIdent`: ptr UncheckedArray[`bucketName`]
      var `globalBucketCountIdent`: int
      var `globalBucketCapIdent`: int
      var `globalLockIdent`: Lock
      var `globalInitIdent`: Atomic[int]
  )

  # ── Timeout knob (per broker type) ──────────────────────────────────
  result.add(
    quote do:
      var `timeoutVarIdent`*: Duration = chronos.seconds(5)
        ## Default timeout for cross-thread requests.

      proc setRequestTimeout*(_: typedesc[`typeIdent`], timeout: Duration) =
        `timeoutVarIdent` = timeout

      proc requestTimeout*(_: typedesc[`typeIdent`]): Duration =
        `timeoutVarIdent`

  )

  # ── Init + grow ──────────────────────────────────────────────────────
  result.add(
    quote do:
      proc `initProcIdent`() =
        if `globalInitIdent`.load(moRelaxed) == 2:
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

      proc `growProcIdent`() =
        let newCap = `globalBucketCapIdent` * 2
        let newBuf =
          cast[ptr UncheckedArray[`bucketName`]](createShared(`bucketName`, newCap))
        for i in 0 ..< `globalBucketCountIdent`:
          newBuf[i] = `globalBucketsIdent`[i]
        `globalBucketsIdent` = newBuf
        `globalBucketCapIdent` = newCap

      proc `shardHintIdent`(): uint32 {.inline.} =
        cast[uint32](cast[uint](currentMtThreadId()) shr 4)

  )

  # ── Threadvar provider storage ──────────────────────────────────────
  var tvNoArgCtxIdent, tvNoArgHandlerIdent: NimNode
  if not zeroArgSig.isNil():
    tvNoArgCtxIdent = ident("g" & typeDisplayName & "TvNoArgCtxs")
    tvNoArgHandlerIdent = ident("g" & typeDisplayName & "TvNoArgHandlers")
    result.add(
      quote do:
        var `tvNoArgCtxIdent` {.threadvar.}: seq[BrokerContext]
        var `tvNoArgHandlerIdent` {.threadvar.}: seq[`zeroArgProviderName`]
    )

  var tvWithArgCtxIdent, tvWithArgHandlerIdent: NimNode
  if not argSig.isNil():
    tvWithArgCtxIdent = ident("g" & typeDisplayName & "TvWithArgCtxs")
    tvWithArgHandlerIdent = ident("g" & typeDisplayName & "TvWithArgHandlers")
    result.add(
      quote do:
        var `tvWithArgCtxIdent` {.threadvar.}: seq[BrokerContext]
        var `tvWithArgHandlerIdent` {.threadvar.}: seq[`argProviderName`]
    )

  # ── sendReply helper (marshals Result into response slot bytes) ──────
  # Protocol:
  #   1. CAS Empty→Writing via pool.beginWrite. If it fails the
  #      requester abandoned; release the slot without writing.
  #   2. Marshal `resp` into slotPayloadPtr(idx).
  #   3. commitWrite (stores size + flips state to Ready, release-ordered).
  #   4. Fire requester's signal.
  result.add(
    quote do:
      proc `sendReplyIdent`(
          pool: ptr ResponseSlotPool,
          slotIdx: uint32,
          requesterSignal: ptr BrokerSignalShared,
          resp: Result[`payloadType`, string],
      ) {.gcsafe, raises: [].} =
        if pool.isNil or slotIdx == EmptyIdx:
          return
        if not pool[].beginWrite(slotIdx):
          # Requester already abandoned — provider owns the release.
          pool[].release(slotIdx, `shardHintIdent`())
          return
        let payloadPtr = pool[].slotPayloadPtr(slotIdx)
        let written =
          try:
            `marshalRespIdent`(payloadPtr, int(pool[].slotPayloadCap), resp)
          except Exception:
            -1
        if written >= 0:
          pool[].commitWrite(slotIdx, uint32(written))
        else:
          # Response exceeded the inline slot — auto-spill onto the heap so the
          # full response is delivered instead of replaced by an err. Falls back
          # to an err only if the spill itself cannot be sized/allocated.
          let needed =
            try:
              `marshalRespSizeIdent`(resp)
            except Exception:
              -1
          var spilled = false
          if needed >= 0 and needed <= `maxDynPayloadLit`:
            let spillBuf = allocShared0(needed)
            if not spillBuf.isNil:
              let w2 =
                try:
                  `marshalRespIdent`(
                    cast[ptr UncheckedArray[byte]](spillBuf), needed, resp
                  )
                except Exception:
                  -1
              if w2 < 0:
                deallocShared(spillBuf)
              else:
                pool[].commitWriteOverflow(slotIdx, spillBuf, uint32(w2))
                spilled = true
          if not spilled:
            # Could not spill (over ceiling / OOM / marshal error) — commit a
            # compact err so the requester gets a clean failure, not garbage.
            let fallback = err(
              Result[`payloadType`, string],
              "RequestBroker(" & `typeNameLit` & "): response too large to deliver",
            )
            let writtenFb =
              try:
                `marshalRespIdent`(payloadPtr, int(pool[].slotPayloadCap), fallback)
              except Exception:
                -1
            if writtenFb < 0:
              pool[].commitWrite(slotIdx, 0'u32)
            else:
              pool[].commitWrite(slotIdx, uint32(writtenFb))
        if not requesterSignal.isNil:
          fireBrokerSignal(requesterSignal)

  )

  # ── handleMsg async (provider-side dispatch of a single ReqMsg) ──────
  let msgIdent = ident("msg")
  let loopCtxIdent = ident("loopCtx")
  let poolIdent = ident("pool")

  var handleBody = newStmtList()

  if not zeroArgSig.isNil():
    let handlerIdent0 = ident("handler0")
    handleBody.add(
      quote do:
        if `msgIdent`.requestKind == 0:
          var `handlerIdent0`: `zeroArgProviderName`
          for i in 0 ..< `tvNoArgCtxIdent`.len:
            if `tvNoArgCtxIdent`[i] == `loopCtxIdent`:
              `handlerIdent0` = `tvNoArgHandlerIdent`[i]
              break
          if `handlerIdent0`.isNil():
            `sendReplyIdent`(
              `poolIdent`,
              `msgIdent`.responseSlotIdx,
              `msgIdent`.requesterSignal,
              err(
                Result[`payloadType`, string],
                "RequestBroker(" & `typeNameLit` & "): no zero-arg provider registered",
              ),
            )
          else:
            let catchedRes = catch:
              await `handlerIdent0`()
            if catchedRes.isErr():
              `sendReplyIdent`(
                `poolIdent`,
                `msgIdent`.responseSlotIdx,
                `msgIdent`.requesterSignal,
                err(
                  Result[`payloadType`, string],
                  "RequestBroker(" & `typeNameLit` & "): provider threw exception: " &
                    catchedRes.error.msg,
                ),
              )
            else:
              let providerRes = catchedRes.get()
              when not (`payloadType` is void):
                if providerRes.isOk():
                  let resultValue = providerRes.get()
                  when compiles(resultValue.isNil()) and
                      not (typeof(resultValue) is string):
                    if resultValue.isNil():
                      `sendReplyIdent`(
                        `poolIdent`,
                        `msgIdent`.responseSlotIdx,
                        `msgIdent`.requesterSignal,
                        err(
                          Result[`payloadType`, string],
                          "RequestBroker(" & `typeNameLit` &
                            "): provider returned nil result",
                        ),
                      )
                      return
              `sendReplyIdent`(
                `poolIdent`, `msgIdent`.responseSlotIdx, `msgIdent`.requesterSignal,
                providerRes,
              )
    )

  if not argSig.isNil():
    let argNameIdents = collectParamNames(argParams)
    let handlerIdent1 = ident("handler1")
    var providerCall = newCall(handlerIdent1)
    for argName in argNameIdents:
      providerCall.add(newDotExpr(msgIdent, argName))

    handleBody.add(
      quote do:
        if `msgIdent`.requestKind == 1:
          var `handlerIdent1`: `argProviderName`
          for i in 0 ..< `tvWithArgCtxIdent`.len:
            if `tvWithArgCtxIdent`[i] == `loopCtxIdent`:
              `handlerIdent1` = `tvWithArgHandlerIdent`[i]
              break
          if `handlerIdent1`.isNil():
            `sendReplyIdent`(
              `poolIdent`,
              `msgIdent`.responseSlotIdx,
              `msgIdent`.requesterSignal,
              err(
                Result[`payloadType`, string],
                "RequestBroker(" & `typeNameLit` &
                  "): no provider registered for input signature",
              ),
            )
          else:
            let catchedRes = catch:
              await `providerCall`
            if catchedRes.isErr():
              `sendReplyIdent`(
                `poolIdent`,
                `msgIdent`.responseSlotIdx,
                `msgIdent`.requesterSignal,
                err(
                  Result[`payloadType`, string],
                  "RequestBroker(" & `typeNameLit` & "): provider threw exception: " &
                    catchedRes.error.msg,
                ),
              )
            else:
              let providerRes = catchedRes.get()
              when not (`payloadType` is void):
                if providerRes.isOk():
                  let resultValue = providerRes.get()
                  when compiles(resultValue.isNil()) and
                      not (typeof(resultValue) is string):
                    if resultValue.isNil():
                      `sendReplyIdent`(
                        `poolIdent`,
                        `msgIdent`.responseSlotIdx,
                        `msgIdent`.requesterSignal,
                        err(
                          Result[`payloadType`, string],
                          "RequestBroker(" & `typeNameLit` &
                            "): provider returned nil result",
                        ),
                      )
                      return
              `sendReplyIdent`(
                `poolIdent`, `msgIdent`.responseSlotIdx, `msgIdent`.requesterSignal,
                providerRes,
              )
    )

  result.add(
    quote do:
      proc `handleMsgIdent`(
          `msgIdent`: `requestMsgName`,
          `loopCtxIdent`: BrokerContext,
          `poolIdent`: ptr ResponseSlotPool,
      ) {.async: (raises: []).} =
        `handleBody`

  )

  # ── Poll fn maker ────────────────────────────────────────────────────
  # Dequeues cell idx from ring, unmarshals ReqMsg, dispatches.  When the
  # ring is closed and empty, registers its (ring, slab, pool) triple for
  # synchronous deferred free at thread exit (see drainPendingRingFrees).
  result.add(
    quote do:
      proc `pollFnMakerIdent`(
          ring: ptr VyukovMpscRing[uint32],
          slab: ptr PayloadSlab,
          pool: ptr ResponseSlotPool,
          loopCtx: BrokerContext,
      ): ThreadDispatchPollFn =
        let capturedRing = ring
        let capturedSlab = slab
        let capturedPool = pool
        let capturedCtx = loopCtx
        return proc(): int {.gcsafe, raises: [].} =
          {.cast(gcsafe).}:
            var cellIdx: uint32
            if not capturedRing.tryDequeue(cellIdx):
              if capturedRing.isClosed():
                # Hand off to the thread-local pending-free registry; the
                # processing-thread proc drains it synchronously after
                # drainAsyncOps. Doing the free asynchronously here ran the
                # refc allocator during shutdown teardown and SEGV'd on
                # Linux + macOS ASAN (PR #13, deferredFreeReqRing path).
                enqueuePendingRingFree(capturedRing, capturedSlab, capturedPool)
                return 2
              return 0
            # Got a cell — unmarshal ReqMsg, dispatch. dataPtr/dataLen resolve
            # the heap-spill buffer when the request spilled, else inline.
            var msg: `requestMsgName`
            let payloadPtr = capturedSlab[].dataPtr(cellIdx)
            let payloadLen = capturedSlab[].dataLen(cellIdx)
            let ok =
              try:
                `unmarshalIdent`(payloadPtr, payloadLen, msg)
              except Exception:
                false
            if ok:
              asyncSpawn `handleMsgIdent`(msg, capturedCtx, capturedPool)
            else:
              error "Failed to unmarshal request payload", requestType = `typeNameLit`
            # Release the cell back to the slab — the unmarshaled msg
            # holds its own copy on this thread's GC heap.
            capturedSlab[].release(cellIdx, `shardHintIdent`())
            return 1

  )

  # ── setProvider impl helper (reused by 4 public overloads) ───────────
  # Allocates ring + slab + pool on the calling thread, registers the
  # bucket, and starts the poller.  Returns Result[void, string].
  let setupBucketIdent = ident("setupBucket" & typeDisplayName)
  result.add(
    quote do:
      proc `setupBucketIdent`(brokerCtx: BrokerContext): Result[void, string] =
        let myThreadId = currentMtThreadId()
        let myThreadGen = currentMtThreadGen()
        var ring: ptr VyukovMpscRing[uint32]
        var slab: ptr PayloadSlab
        var pool: ptr ResponseSlotPool
        withLock(`globalLockIdent`):
          for i in 0 ..< `globalBucketCountIdent`:
            if `globalBucketsIdent`[i].brokerCtx == brokerCtx:
              if `globalBucketsIdent`[i].threadId == myThreadId and
                  `globalBucketsIdent`[i].threadGen == myThreadGen:
                return ok() # already set on this thread
              return err(
                "RequestBroker(" & `typeNameLit` &
                  "): provider already set from another thread"
              )
          if `globalBucketCountIdent` >= `globalBucketCapIdent`:
            `growProcIdent`()
          ring = newVyukovMpscRing[uint32](`queueDepthLit`)
          slab = cast[ptr PayloadSlab](createShared(PayloadSlab, 1))
          initPayloadSlab(
            slab[],
            capacity = uint32(`slabCapacityLit`),
            payloadBytes = uint32(`payloadBytesLit`),
            nShards = `freeListShardsLit`,
          )
          pool = cast[ptr ResponseSlotPool](createShared(ResponseSlotPool, 1))
          initResponseSlotPool(
            pool[],
            capacity = uint32(`responseSlotsLit`),
            maxPayloadBytes = uint32(`responseBytesLit`),
            nShards = `freeListShardsLit`,
          )
          let providerSig = getOrInitBrokerSignal()
          let idx = `globalBucketCountIdent`
          `globalBucketsIdent`[idx] = `bucketName`(
            brokerCtx: brokerCtx,
            ring: ring,
            slab: slab,
            responseSlotPool: pool,
            providerSignal: providerSig,
            threadId: myThreadId,
            threadGen: myThreadGen,
          )
          `globalBucketCountIdent` += 1
        registerBrokerPoller(`pollFnMakerIdent`(ring, slab, pool, brokerCtx))
        ensureBrokerDispatchStarted()
        ok()

  )

  # ── setProvider (zero-arg) ──────────────────────────────────────────
  if not zeroArgSig.isNil():
    result.add(
      quote do:
        proc setProvider*(
            _: typedesc[`typeIdent`],
            brokerCtx: BrokerContext,
            handler: `zeroArgProviderName`,
        ): Result[void, string] =
          `initProcIdent`()
          let myThreadGen = currentMtThreadGen()
          for i in 0 ..< `tvNoArgCtxIdent`.len:
            if `tvNoArgCtxIdent`[i] == brokerCtx:
              var isStale = true
              withLock(`globalLockIdent`):
                for j in 0 ..< `globalBucketCountIdent`:
                  if `globalBucketsIdent`[j].brokerCtx == brokerCtx and
                      `globalBucketsIdent`[j].threadId == currentMtThreadId() and
                      `globalBucketsIdent`[j].threadGen == myThreadGen:
                    isStale = false
                    break
              if isStale:
                `tvNoArgCtxIdent`.del(i)
                `tvNoArgHandlerIdent`.del(i)
                break
              else:
                return err(
                  "RequestBroker(" & `typeNameLit` &
                    "): provider already set for broker context"
                )
          `tvNoArgCtxIdent`.add(brokerCtx)
          `tvNoArgHandlerIdent`.add(handler)
          let r = `setupBucketIdent`(brokerCtx)
          if r.isErr():
            `tvNoArgCtxIdent`.setLen(`tvNoArgCtxIdent`.len - 1)
            `tvNoArgHandlerIdent`.setLen(`tvNoArgHandlerIdent`.len - 1)
            return r
          ok()

        proc setProvider*(
            _: typedesc[`typeIdent`], handler: `zeroArgProviderName`
        ): Result[void, string] =
          setProvider(`typeIdent`, DefaultBrokerContext, handler)

    )

  # ── setProvider (with-args) ─────────────────────────────────────────
  if not argSig.isNil():
    result.add(
      quote do:
        proc setProvider*(
            _: typedesc[`typeIdent`],
            brokerCtx: BrokerContext,
            handler: `argProviderName`,
        ): Result[void, string] =
          `initProcIdent`()
          let myThreadGen = currentMtThreadGen()
          for i in 0 ..< `tvWithArgCtxIdent`.len:
            if `tvWithArgCtxIdent`[i] == brokerCtx:
              var isStale = true
              withLock(`globalLockIdent`):
                for j in 0 ..< `globalBucketCountIdent`:
                  if `globalBucketsIdent`[j].brokerCtx == brokerCtx and
                      `globalBucketsIdent`[j].threadId == currentMtThreadId() and
                      `globalBucketsIdent`[j].threadGen == myThreadGen:
                    isStale = false
                    break
              if isStale:
                `tvWithArgCtxIdent`.del(i)
                `tvWithArgHandlerIdent`.del(i)
                break
              else:
                return err(
                  "RequestBroker(" & `typeNameLit` &
                    "): provider already set for broker context"
                )
          `tvWithArgCtxIdent`.add(brokerCtx)
          `tvWithArgHandlerIdent`.add(handler)
          let r = `setupBucketIdent`(brokerCtx)
          if r.isErr():
            `tvWithArgCtxIdent`.setLen(`tvWithArgCtxIdent`.len - 1)
            `tvWithArgHandlerIdent`.setLen(`tvWithArgHandlerIdent`.len - 1)
            return r
          ok()

        proc setProvider*(
            _: typedesc[`typeIdent`], handler: `argProviderName`
        ): Result[void, string] =
          setProvider(`typeIdent`, DefaultBrokerContext, handler)

    )

  # ── request helper: send and await one ReqMsg cross-thread ──────────
  # Returns the response Result or an err on timeout / queue full.
  let sendAndAwaitIdent = ident("sendAndAwait" & typeDisplayName)
  result.add(
    quote do:
      proc `sendAndAwaitIdent`(
          ring: ptr VyukovMpscRing[uint32],
          slab: ptr PayloadSlab,
          pool: ptr ResponseSlotPool,
          providerSignal: ptr BrokerSignalShared,
          msg: sink `requestMsgName`,
      ): Future[Result[`payloadType`, string]] {.async: (raises: []).} =
        ensureBrokerDispatchStarted()
        let mySignal = getOrInitBrokerSignal()
        # Reserve the response slot.
        let slotIdx = pool[].claim(`shardHintIdent`())
        if slotIdx == EmptyIdx:
          return
            err("RequestBroker(" & `typeNameLit` & "): response slot pool exhausted")
        # Reserve a slab cell, marshal ReqMsg into it.
        let cellIdx = slab[].claim(`shardHintIdent`())
        if cellIdx == EmptyIdx:
          pool[].release(slotIdx, `shardHintIdent`())
          return err("RequestBroker(" & `typeNameLit` & "): request slab exhausted")
        let cellPtr = slab[].cellPtr(cellIdx)
        let payloadPtr = slab[].cellPayloadPtr(cellIdx)
        var msgCopy = msg
        msgCopy.responseSlotIdx = slotIdx
        msgCopy.requesterSignal = mySignal
        let written =
          try:
            `marshalIdent`(payloadPtr, int(slab[].cellPayloadCap), msgCopy)
          except Exception:
            -1
        if written >= 0:
          cellPtr.payloadSize = uint32(written)
        else:
          # Auto-spill the request onto the heap instead of failing.
          let needed =
            try:
              `marshalSizeIdent`(msgCopy)
            except Exception:
              -1
          if needed < 0 or needed > `maxDynPayloadLit`:
            slab[].release(cellIdx, `shardHintIdent`())
            pool[].release(slotIdx, `shardHintIdent`())
            return err(
              "RequestBroker(" & `typeNameLit` &
                "): request payload exceeds maxDynamicPayloadBytes"
            )
          let spillBuf = allocShared0(needed)
          if spillBuf.isNil:
            slab[].release(cellIdx, `shardHintIdent`())
            pool[].release(slotIdx, `shardHintIdent`())
            return
              err("RequestBroker(" & `typeNameLit` & "): request spill alloc failed")
          let w2 =
            try:
              `marshalIdent`(cast[ptr UncheckedArray[byte]](spillBuf), needed, msgCopy)
            except Exception:
              -1
          if w2 < 0:
            deallocShared(spillBuf)
            slab[].release(cellIdx, `shardHintIdent`())
            pool[].release(slotIdx, `shardHintIdent`())
            return err("RequestBroker(" & `typeNameLit` & "): request marshal failed")
          slab[].setOverflow(cellIdx, spillBuf, uint32(w2))
        cellPtr.refcount.store(1, moRelease)
        if not ring.tryEnqueue(cellIdx):
          slab[].release(cellIdx, `shardHintIdent`())
          pool[].release(slotIdx, `shardHintIdent`())
          return err("RequestBroker(" & `typeNameLit` & "): provider queue full")
        fireBrokerSignal(providerSignal)
        # Register a one-shot response poller for this slot.
        let responseFut =
          newFuture[Result[`payloadType`, string]]("request." & `typeNameLit`)
        let capturedPool = pool
        let capturedSlotIdx = slotIdx
        let capturedResponseFut = responseFut
        registerBrokerPoller(
          proc(): int {.gcsafe, raises: [].} =
            {.cast(gcsafe).}:
              if not capturedPool[].readyState(capturedSlotIdx):
                return 0
              # Unmarshal Result from slot bytes on THIS (requester) thread,
              # so any string/seq inside lives on this thread's GC heap.
              # This is the §2.2 fix: no cross-thread `=copy` of the typed
              # Result value.
              var decoded: Result[`payloadType`, string]
              let payloadPtr = capturedPool[].respDataPtr(capturedSlotIdx)
              let payloadSize = capturedPool[].respDataLen(capturedSlotIdx)
              let ok =
                try:
                  `unmarshalRespIdent`(payloadPtr, payloadSize, decoded)
                except Exception:
                  false
              if not ok:
                decoded = err(
                  Result[`payloadType`, string],
                  "RequestBroker(" & `typeNameLit` & "): response unmarshal failed",
                )
              if not capturedResponseFut.finished:
                capturedResponseFut.complete(decoded)
              capturedPool[].release(capturedSlotIdx, `shardHintIdent`())
              return 2
        )
        let completedRes = catch:
          await withTimeout(responseFut, `timeoutVarIdent`)
        if completedRes.isErr():
          responseFut.cancelSoon()
          discard capturedPool[].abandon(capturedSlotIdx)
          return err(
            "RequestBroker(" & `typeNameLit` & "): recv failed: " &
              completedRes.error.msg
          )
        if not completedRes.get():
          responseFut.cancelSoon()
          discard capturedPool[].abandon(capturedSlotIdx)
          return err(
            "RequestBroker(" & `typeNameLit` & "): cross-thread request timed out after " &
              $`timeoutVarIdent`
          )
        let recvRes = catch:
          responseFut.read()
        if recvRes.isErr():
          return err(
            "RequestBroker(" & `typeNameLit` & "): recv failed: " & recvRes.error.msg
          )
        recvRes.get()

  )

  # ── blockingRequest helper: same as above but synchronous ────────────
  let blockingSendAndAwaitIdent = ident("blockingSendAndAwait" & typeDisplayName)
  result.add(
    quote do:
      proc `blockingSendAndAwaitIdent`(
          ring: ptr VyukovMpscRing[uint32],
          slab: ptr PayloadSlab,
          pool: ptr ResponseSlotPool,
          providerSignal: ptr BrokerSignalShared,
          msg: sink `requestMsgName`,
      ): Result[`payloadType`, string] {.gcsafe, raises: [].} =
        let slotIdx = pool[].claim(`shardHintIdent`())
        if slotIdx == EmptyIdx:
          return
            err("RequestBroker(" & `typeNameLit` & "): response slot pool exhausted")
        let cellIdx = slab[].claim(`shardHintIdent`())
        if cellIdx == EmptyIdx:
          pool[].release(slotIdx, `shardHintIdent`())
          return err("RequestBroker(" & `typeNameLit` & "): request slab exhausted")
        let cellPtr = slab[].cellPtr(cellIdx)
        let payloadPtr = slab[].cellPayloadPtr(cellIdx)
        var msgCopy = msg
        msgCopy.responseSlotIdx = slotIdx
        msgCopy.requesterSignal = nil # no async loop on this thread
        let written =
          try:
            `marshalIdent`(payloadPtr, int(slab[].cellPayloadCap), msgCopy)
          except Exception:
            -1
        if written >= 0:
          cellPtr.payloadSize = uint32(written)
        else:
          # Auto-spill the request onto the heap instead of failing.
          let needed =
            try:
              `marshalSizeIdent`(msgCopy)
            except Exception:
              -1
          if needed < 0 or needed > `maxDynPayloadLit`:
            slab[].release(cellIdx, `shardHintIdent`())
            pool[].release(slotIdx, `shardHintIdent`())
            return err(
              "RequestBroker(" & `typeNameLit` &
                "): request payload exceeds maxDynamicPayloadBytes"
            )
          let spillBuf = allocShared0(needed)
          if spillBuf.isNil:
            slab[].release(cellIdx, `shardHintIdent`())
            pool[].release(slotIdx, `shardHintIdent`())
            return
              err("RequestBroker(" & `typeNameLit` & "): request spill alloc failed")
          let w2 =
            try:
              `marshalIdent`(cast[ptr UncheckedArray[byte]](spillBuf), needed, msgCopy)
            except Exception:
              -1
          if w2 < 0:
            deallocShared(spillBuf)
            slab[].release(cellIdx, `shardHintIdent`())
            pool[].release(slotIdx, `shardHintIdent`())
            return err("RequestBroker(" & `typeNameLit` & "): request marshal failed")
          slab[].setOverflow(cellIdx, spillBuf, uint32(w2))
        cellPtr.refcount.store(1, moRelease)
        if not ring.tryEnqueue(cellIdx):
          slab[].release(cellIdx, `shardHintIdent`())
          pool[].release(slotIdx, `shardHintIdent`())
          return err("RequestBroker(" & `typeNameLit` & "): provider queue full")
        fireBrokerSignal(providerSignal)
        # Busy-poll the response slot until ready or timeout.
        let deadline = Moment.now() + `timeoutVarIdent`
        while Moment.now() < deadline:
          if pool[].readyState(slotIdx):
            var decoded: Result[`payloadType`, string]
            let payloadPtr = pool[].respDataPtr(slotIdx)
            let payloadSize = pool[].respDataLen(slotIdx)
            let ok =
              try:
                `unmarshalRespIdent`(payloadPtr, payloadSize, decoded)
              except Exception:
                false
            pool[].release(slotIdx, `shardHintIdent`())
            if ok:
              return decoded
            return
              err("RequestBroker(" & `typeNameLit` & "): response unmarshal failed")
          sleep(1)
        # Timeout: abandon the slot so a late provider write returns
        # the slot to the pool instead of leaving it stranded.
        discard pool[].abandon(slotIdx)
        return err(
          "RequestBroker(" & `typeNameLit` & "): cross-thread request timed out after " &
            $`timeoutVarIdent`
        )

  )

  # ── request (zero-arg) ──────────────────────────────────────────────
  if not zeroArgSig.isNil():
    result.add(
      quote do:
        proc request*(
            _: typedesc[`typeIdent`], brokerCtx: BrokerContext
        ): Future[Result[`payloadType`, string]] {.async: (raises: []).} =
          `initProcIdent`()
          var ring: ptr VyukovMpscRing[uint32]
          var slab: ptr PayloadSlab
          var pool: ptr ResponseSlotPool
          var providerSignal: ptr BrokerSignalShared
          var sameThread = false
          let myThreadGen = currentMtThreadGen()
          withLock(`globalLockIdent`):
            for i in 0 ..< `globalBucketCountIdent`:
              if `globalBucketsIdent`[i].brokerCtx == brokerCtx:
                if `globalBucketsIdent`[i].threadId == currentMtThreadId() and
                    `globalBucketsIdent`[i].threadGen == myThreadGen:
                  sameThread = true
                else:
                  ring = `globalBucketsIdent`[i].ring
                  slab = `globalBucketsIdent`[i].slab
                  pool = `globalBucketsIdent`[i].responseSlotPool
                  providerSignal = `globalBucketsIdent`[i].providerSignal
                break
          if sameThread:
            var provider: `zeroArgProviderName`
            for i in 0 ..< `tvNoArgCtxIdent`.len:
              if `tvNoArgCtxIdent`[i] == brokerCtx:
                provider = `tvNoArgHandlerIdent`[i]
                break
            if provider.isNil():
              return err(
                "RequestBroker(" & `typeNameLit` & "): no zero-arg provider registered"
              )
            let catchedRes = catch:
              await provider()
            if catchedRes.isErr():
              return err(
                "RequestBroker(" & `typeNameLit` & "): provider threw exception: " &
                  catchedRes.error.msg
              )
            return catchedRes.get()
          if ring.isNil:
            return err(
              "RequestBroker(" & `typeNameLit` &
                "): no zero-arg provider registered for broker context " & $brokerCtx
            )
          var msg = `requestMsgName`(requestKind: 0)
          return await `sendAndAwaitIdent`(ring, slab, pool, providerSignal, msg)

        proc request*(
            _: typedesc[`typeIdent`]
        ): Future[Result[`payloadType`, string]] {.async: (raises: []).} =
          return await request(`typeIdent`, DefaultBrokerContext)

    )
  else:
    result.add(
      quote do:
        proc request*(
            _: typedesc[`typeIdent`]
        ): Future[Result[`payloadType`, string]] {.async: (raises: []).} =
          return
            err("RequestBroker(" & `typeNameLit` & "): no zero-arg provider registered")

    )

  # ── blockingRequest (zero-arg) ──────────────────────────────────────
  if not zeroArgSig.isNil():
    result.add(
      quote do:
        proc blockingRequest*(
            _: typedesc[`typeIdent`], brokerCtx: BrokerContext
        ): Result[`payloadType`, string] {.gcsafe, raises: [].} =
          `initProcIdent`()
          var ring: ptr VyukovMpscRing[uint32]
          var slab: ptr PayloadSlab
          var pool: ptr ResponseSlotPool
          var providerSignal: ptr BrokerSignalShared
          var sameThread = false
          let myThreadGen = currentMtThreadGen()
          withLock(`globalLockIdent`):
            for i in 0 ..< `globalBucketCountIdent`:
              if `globalBucketsIdent`[i].brokerCtx == brokerCtx:
                if `globalBucketsIdent`[i].threadId == currentMtThreadId() and
                    `globalBucketsIdent`[i].threadGen == myThreadGen:
                  sameThread = true
                else:
                  ring = `globalBucketsIdent`[i].ring
                  slab = `globalBucketsIdent`[i].slab
                  pool = `globalBucketsIdent`[i].responseSlotPool
                  providerSignal = `globalBucketsIdent`[i].providerSignal
                break
          if sameThread:
            var provider: `zeroArgProviderName`
            for i in 0 ..< `tvNoArgCtxIdent`.len:
              if `tvNoArgCtxIdent`[i] == brokerCtx:
                provider = `tvNoArgHandlerIdent`[i]
                break
            if provider.isNil():
              return err(
                "RequestBroker(" & `typeNameLit` & "): no zero-arg provider registered"
              )
            let catchedRes = catch:
              blockingAwait(provider())
            if catchedRes.isErr():
              return err(
                "RequestBroker(" & `typeNameLit` & "): provider threw exception: " &
                  catchedRes.error.msg
              )
            return catchedRes.get()
          if ring.isNil:
            return err(
              "RequestBroker(" & `typeNameLit` &
                "): no zero-arg provider registered for broker context " & $brokerCtx
            )
          var msg = `requestMsgName`(requestKind: 0)
          `blockingSendAndAwaitIdent`(ring, slab, pool, providerSignal, msg)

        proc blockingRequest*(
            _: typedesc[`typeIdent`]
        ): Result[`payloadType`, string] {.gcsafe, raises: [].} =
          blockingRequest(`typeIdent`, DefaultBrokerContext)

    )
  else:
    result.add(
      quote do:
        proc blockingRequest*(
            _: typedesc[`typeIdent`]
        ): Result[`payloadType`, string] {.gcsafe, raises: [].} =
          return
            err("RequestBroker(" & `typeNameLit` & "): no zero-arg provider registered")

    )

  # ── request (with-args) ─────────────────────────────────────────────
  if not argSig.isNil():
    let requestParamDefs = cloneParams(argParams)
    let argNameIdents = collectParamNames(requestParamDefs)

    # Build the keyed (ctx-explicit) request proc.
    let reqPragmas = quote:
      {.async: (raises: []).}
    let typedescParam =
      newTree(nnkBracketExpr, ident("typedesc"), copyNimTree(typeIdent))

    var keyedFormalParams = newTree(nnkFormalParams)
    keyedFormalParams.add(copyNimTree(returnType))
    keyedFormalParams.add(
      newTree(nnkIdentDefs, ident("_"), typedescParam, newEmptyNode())
    )
    keyedFormalParams.add(
      newTree(nnkIdentDefs, ident("brokerCtx"), ident("BrokerContext"), newEmptyNode())
    )
    for paramDef in requestParamDefs:
      keyedFormalParams.add(paramDef)

    let providerSym = genSym(nskVar, "provider")
    var providerCall = newCall(providerSym)
    for argName in argNameIdents:
      providerCall.add(argName)

    var msgCtor = newTree(nnkObjConstr, requestMsgName)
    msgCtor.add(newTree(nnkExprColonExpr, ident("requestKind"), newLit(1)))
    for argName in argNameIdents:
      msgCtor.add(newTree(nnkExprColonExpr, argName, argName))

    let keyedBody = quote:
      `initProcIdent`()
      var ring: ptr VyukovMpscRing[uint32]
      var slab: ptr PayloadSlab
      var pool: ptr ResponseSlotPool
      var providerSignal: ptr BrokerSignalShared
      var sameThread = false
      let myThreadGen = currentMtThreadGen()
      withLock(`globalLockIdent`):
        for i in 0 ..< `globalBucketCountIdent`:
          if `globalBucketsIdent`[i].brokerCtx == brokerCtx:
            if `globalBucketsIdent`[i].threadId == currentMtThreadId() and
                `globalBucketsIdent`[i].threadGen == myThreadGen:
              sameThread = true
            else:
              ring = `globalBucketsIdent`[i].ring
              slab = `globalBucketsIdent`[i].slab
              pool = `globalBucketsIdent`[i].responseSlotPool
              providerSignal = `globalBucketsIdent`[i].providerSignal
            break
      if sameThread:
        var `providerSym`: `argProviderName`
        for i in 0 ..< `tvWithArgCtxIdent`.len:
          if `tvWithArgCtxIdent`[i] == brokerCtx:
            `providerSym` = `tvWithArgHandlerIdent`[i]
            break
        if `providerSym`.isNil():
          return err(
            "RequestBroker(" & `typeNameLit` &
              "): no provider registered for input signature"
          )
        let catchedRes = catch:
          await `providerCall`
        if catchedRes.isErr():
          return err(
            "RequestBroker(" & `typeNameLit` & "): provider threw exception: " &
              catchedRes.error.msg
          )
        return catchedRes.get()
      if ring.isNil:
        return err(
          "RequestBroker(" & `typeNameLit` &
            "): no provider registered for broker context " & $brokerCtx
        )
      var msg = `msgCtor`
      return await `sendAndAwaitIdent`(ring, slab, pool, providerSignal, msg)

    result.add(
      newTree(
        nnkProcDef,
        postfix(ident("request"), "*"),
        newEmptyNode(),
        newEmptyNode(),
        keyedFormalParams,
        reqPragmas,
        newEmptyNode(),
        keyedBody,
      )
    )

    # Non-keyed forwarder.
    var nonKeyedFormalParams = newTree(nnkFormalParams)
    nonKeyedFormalParams.add(copyNimTree(returnType))
    nonKeyedFormalParams.add(
      newTree(nnkIdentDefs, ident("_"), typedescParam, newEmptyNode())
    )
    for paramDef in cloneParams(argParams):
      nonKeyedFormalParams.add(paramDef)

    var forwardCall = newCall(ident("request"))
    forwardCall.add(copyNimTree(typeIdent))
    forwardCall.add(ident("DefaultBrokerContext"))
    for argName in argNameIdents:
      forwardCall.add(argName)
    let forwardBody = quote:
      return await `forwardCall`

    result.add(
      newTree(
        nnkProcDef,
        postfix(ident("request"), "*"),
        newEmptyNode(),
        newEmptyNode(),
        nonKeyedFormalParams,
        reqPragmas,
        newEmptyNode(),
        forwardBody,
      )
    )

  # ── blockingRequest (with-args) ─────────────────────────────────────
  if not argSig.isNil():
    let brParamDefs = cloneParams(argParams)
    let brArgNameIdents = collectParamNames(brParamDefs)
    let brPragmas = quote:
      {.gcsafe, raises: [].}
    let typedescParam =
      newTree(nnkBracketExpr, ident("typedesc"), copyNimTree(typeIdent))

    var brKeyedFormalParams = newTree(nnkFormalParams)
    brKeyedFormalParams.add(
      newTree(nnkBracketExpr, ident("Result"), copyNimTree(typeIdent), ident("string"))
    )
    brKeyedFormalParams.add(
      newTree(nnkIdentDefs, ident("_"), typedescParam, newEmptyNode())
    )
    brKeyedFormalParams.add(
      newTree(nnkIdentDefs, ident("brokerCtx"), ident("BrokerContext"), newEmptyNode())
    )
    for paramDef in brParamDefs:
      brKeyedFormalParams.add(paramDef)

    let brProviderSym = genSym(nskVar, "provider")
    var brProviderCall = newCall(brProviderSym)
    for argName in brArgNameIdents:
      brProviderCall.add(argName)

    var brMsgCtor = newTree(nnkObjConstr, requestMsgName)
    brMsgCtor.add(newTree(nnkExprColonExpr, ident("requestKind"), newLit(1)))
    for argName in brArgNameIdents:
      brMsgCtor.add(newTree(nnkExprColonExpr, argName, argName))

    let brKeyedBody = quote:
      `initProcIdent`()
      var ring: ptr VyukovMpscRing[uint32]
      var slab: ptr PayloadSlab
      var pool: ptr ResponseSlotPool
      var providerSignal: ptr BrokerSignalShared
      var sameThread = false
      let myThreadGen = currentMtThreadGen()
      withLock(`globalLockIdent`):
        for i in 0 ..< `globalBucketCountIdent`:
          if `globalBucketsIdent`[i].brokerCtx == brokerCtx:
            if `globalBucketsIdent`[i].threadId == currentMtThreadId() and
                `globalBucketsIdent`[i].threadGen == myThreadGen:
              sameThread = true
            else:
              ring = `globalBucketsIdent`[i].ring
              slab = `globalBucketsIdent`[i].slab
              pool = `globalBucketsIdent`[i].responseSlotPool
              providerSignal = `globalBucketsIdent`[i].providerSignal
            break
      if sameThread:
        var `brProviderSym`: `argProviderName`
        for i in 0 ..< `tvWithArgCtxIdent`.len:
          if `tvWithArgCtxIdent`[i] == brokerCtx:
            `brProviderSym` = `tvWithArgHandlerIdent`[i]
            break
        if `brProviderSym`.isNil():
          return err(
            "RequestBroker(" & `typeNameLit` &
              "): no provider registered for input signature"
          )
        let catchedRes = catch:
          blockingAwait(`brProviderCall`)
        if catchedRes.isErr():
          return err(
            "RequestBroker(" & `typeNameLit` & "): provider threw exception: " &
              catchedRes.error.msg
          )
        return catchedRes.get()
      if ring.isNil:
        return err(
          "RequestBroker(" & `typeNameLit` &
            "): no provider registered for broker context " & $brokerCtx
        )
      var msg = `brMsgCtor`
      `blockingSendAndAwaitIdent`(ring, slab, pool, providerSignal, msg)

    result.add(
      newTree(
        nnkProcDef,
        postfix(ident("blockingRequest"), "*"),
        newEmptyNode(),
        newEmptyNode(),
        brKeyedFormalParams,
        brPragmas,
        newEmptyNode(),
        brKeyedBody,
      )
    )

    # Non-keyed forwarder.
    var brNonKeyedFormalParams = newTree(nnkFormalParams)
    brNonKeyedFormalParams.add(
      newTree(nnkBracketExpr, ident("Result"), copyNimTree(typeIdent), ident("string"))
    )
    brNonKeyedFormalParams.add(
      newTree(nnkIdentDefs, ident("_"), typedescParam, newEmptyNode())
    )
    for paramDef in cloneParams(argParams):
      brNonKeyedFormalParams.add(paramDef)

    var brForwardCall = newCall(ident("blockingRequest"))
    brForwardCall.add(copyNimTree(typeIdent))
    brForwardCall.add(ident("DefaultBrokerContext"))
    for argName in brArgNameIdents:
      brForwardCall.add(argName)
    let brForwardBody = quote:
      `brForwardCall`

    result.add(
      newTree(
        nnkProcDef,
        postfix(ident("blockingRequest"), "*"),
        newEmptyNode(),
        newEmptyNode(),
        brNonKeyedFormalParams,
        brPragmas,
        newEmptyNode(),
        brForwardBody,
      )
    )

  # ── clearProvider ───────────────────────────────────────────────────
  let brokerCtxParam = ident("brokerCtx")
  var tvCleanup = newStmtList()
  if not zeroArgSig.isNil():
    tvCleanup.add(
      quote do:
        for i in countdown(`tvNoArgCtxIdent`.len - 1, 0):
          if `tvNoArgCtxIdent`[i] == `brokerCtxParam`:
            `tvNoArgCtxIdent`.del(i)
            `tvNoArgHandlerIdent`.del(i)
            break
    )
  if not argSig.isNil():
    tvCleanup.add(
      quote do:
        for i in countdown(`tvWithArgCtxIdent`.len - 1, 0):
          if `tvWithArgCtxIdent`[i] == `brokerCtxParam`:
            `tvWithArgCtxIdent`.del(i)
            `tvWithArgHandlerIdent`.del(i)
            break
    )

  let clearBody = quote:
    `initProcIdent`()
    var ring: ptr VyukovMpscRing[uint32]
    var providerSignal: ptr BrokerSignalShared
    var isProviderThread = false
    let myThreadGen = currentMtThreadGen()
    withLock(`globalLockIdent`):
      var foundIdx = -1
      for i in 0 ..< `globalBucketCountIdent`:
        if `globalBucketsIdent`[i].brokerCtx == `brokerCtxParam`:
          ring = `globalBucketsIdent`[i].ring
          providerSignal = `globalBucketsIdent`[i].providerSignal
          isProviderThread = (
            `globalBucketsIdent`[i].threadId == currentMtThreadId() and
            `globalBucketsIdent`[i].threadGen == myThreadGen
          )
          foundIdx = i
          break
      if foundIdx >= 0:
        for i in foundIdx ..< `globalBucketCountIdent` - 1:
          `globalBucketsIdent`[i] = `globalBucketsIdent`[i + 1]
        `globalBucketCountIdent` -= 1
    if isProviderThread:
      `tvCleanup`
    if not ring.isNil:
      ring.close()
      fireBrokerSignal(providerSignal)

  var formalParamsClear = newTree(nnkFormalParams)
  formalParamsClear.add(newEmptyNode())
  formalParamsClear.add(
    newTree(
      nnkIdentDefs,
      ident("_"),
      newTree(nnkBracketExpr, ident("typedesc"), copyNimTree(typeIdent)),
      newEmptyNode(),
    )
  )
  formalParamsClear.add(
    newTree(nnkIdentDefs, brokerCtxParam, ident("BrokerContext"), newEmptyNode())
  )
  result.add(
    newTree(
      nnkProcDef,
      postfix(ident("clearProvider"), "*"),
      newEmptyNode(),
      newEmptyNode(),
      formalParamsClear,
      newEmptyNode(),
      newEmptyNode(),
      clearBody,
    )
  )

  result.add(
    quote do:
      proc clearProvider*(_: typedesc[`typeIdent`]) =
        clearProvider(`typeIdent`, DefaultBrokerContext)

  )

  # ── isProvided ─────────────────────────────────────────────────────
  let isProvidedCtxParam = ident("brokerCtx")
  let isProvidedBody = quote:
    `initProcIdent`()
    withLock(`globalLockIdent`):
      for i in 0 ..< `globalBucketCountIdent`:
        if `globalBucketsIdent`[i].brokerCtx == `isProvidedCtxParam`:
          return true
    return false

  var formalParamsIsProvided = newTree(nnkFormalParams)
  formalParamsIsProvided.add(ident("bool"))
  formalParamsIsProvided.add(
    newTree(
      nnkIdentDefs,
      ident("_"),
      newTree(nnkBracketExpr, ident("typedesc"), copyNimTree(typeIdent)),
      newEmptyNode(),
    )
  )
  formalParamsIsProvided.add(
    newTree(nnkIdentDefs, isProvidedCtxParam, ident("BrokerContext"), newEmptyNode())
  )

  result.add(
    newTree(
      nnkProcDef,
      postfix(ident("isProvided"), "*"),
      newEmptyNode(),
      newEmptyNode(),
      formalParamsIsProvided,
      newEmptyNode(),
      newEmptyNode(),
      isProvidedBody,
    )
  )

  result.add(
    quote do:
      proc isProvided*(_: typedesc[`typeIdent`]): bool =
        isProvided(`typeIdent`, DefaultBrokerContext)

  )

  # ── getCurrentProvider / replaceProvider (owning thread only) ───────
  # MT introspection reads the per-thread threadvar slot, so it MUST be called
  # on the provider's owning thread (the one that ran setProvider). Cross-thread
  # introspection is not supported (the shared bucket holds a ring, not the
  # closure). Distinct zero-arg getter name avoids return-type-only overloads;
  # replaceProvider overloads on the handler proc type.
  if not zeroArgSig.isNil():
    result.add(
      quote do:
        proc getCurrentProviderNoArgs*(
            _: typedesc[`typeIdent`], brokerCtx: BrokerContext
        ): Option[`zeroArgProviderName`] =
          for i in 0 ..< `tvNoArgCtxIdent`.len:
            if `tvNoArgCtxIdent`[i] == brokerCtx:
              return some(`tvNoArgHandlerIdent`[i])
          none(`zeroArgProviderName`)

        proc replaceProvider*(
            _: typedesc[`typeIdent`],
            brokerCtx: BrokerContext,
            handler: `zeroArgProviderName`,
        ): Result[void, string] =
          ## Replace-or-insert on the owning thread; never errors on an existing
          ## entry (unlike setProvider). A new ctx also sets up its bucket.
          `initProcIdent`()
          for i in 0 ..< `tvNoArgCtxIdent`.len:
            if `tvNoArgCtxIdent`[i] == brokerCtx:
              `tvNoArgHandlerIdent`[i] = handler
              return ok()
          `tvNoArgCtxIdent`.add(brokerCtx)
          `tvNoArgHandlerIdent`.add(handler)
          let r = `setupBucketIdent`(brokerCtx)
          if r.isErr():
            `tvNoArgCtxIdent`.setLen(`tvNoArgCtxIdent`.len - 1)
            `tvNoArgHandlerIdent`.setLen(`tvNoArgHandlerIdent`.len - 1)
            return r
          ok()

        template withMockProvider*(
            t: typedesc[`typeIdent`],
            brokerCtx: BrokerContext,
            mock: `zeroArgProviderName`,
            body: untyped,
        ): untyped =
          ## Owning-thread only. Install `mock` for the duration of `body`, then
          ## restore the captured provider (or clear it if none was set).
          let savedMockProvider = getCurrentProviderNoArgs(t, brokerCtx)
          discard replaceProvider(t, brokerCtx, mock)
          try:
            body
          finally:
            if savedMockProvider.isSome:
              discard replaceProvider(t, brokerCtx, savedMockProvider.get)
            else:
              clearProvider(t, brokerCtx)

    )
  if not argSig.isNil():
    result.add(
      quote do:
        proc getCurrentProvider*(
            _: typedesc[`typeIdent`], brokerCtx: BrokerContext
        ): Option[`argProviderName`] =
          for i in 0 ..< `tvWithArgCtxIdent`.len:
            if `tvWithArgCtxIdent`[i] == brokerCtx:
              return some(`tvWithArgHandlerIdent`[i])
          none(`argProviderName`)

        proc replaceProvider*(
            _: typedesc[`typeIdent`],
            brokerCtx: BrokerContext,
            handler: `argProviderName`,
        ): Result[void, string] =
          ## Replace-or-insert on the owning thread; never errors on an existing
          ## entry (unlike setProvider). A new ctx also sets up its bucket.
          `initProcIdent`()
          for i in 0 ..< `tvWithArgCtxIdent`.len:
            if `tvWithArgCtxIdent`[i] == brokerCtx:
              `tvWithArgHandlerIdent`[i] = handler
              return ok()
          `tvWithArgCtxIdent`.add(brokerCtx)
          `tvWithArgHandlerIdent`.add(handler)
          let r = `setupBucketIdent`(brokerCtx)
          if r.isErr():
            `tvWithArgCtxIdent`.setLen(`tvWithArgCtxIdent`.len - 1)
            `tvWithArgHandlerIdent`.setLen(`tvWithArgHandlerIdent`.len - 1)
            return r
          ok()

        template withMockProvider*(
            t: typedesc[`typeIdent`],
            brokerCtx: BrokerContext,
            mock: `argProviderName`,
            body: untyped,
        ): untyped =
          ## Owning-thread only. Install `mock` for the duration of `body`, then
          ## restore the captured provider (or clear it if none was set).
          let savedMockProvider = getCurrentProvider(t, brokerCtx)
          discard replaceProvider(t, brokerCtx, mock)
          try:
            body
          finally:
            if savedMockProvider.isSome:
              discard replaceProvider(t, brokerCtx, savedMockProvider.get)
            else:
              clearProvider(t, brokerCtx)

    )

  # ── bind / rebind provider sugar (issue #42) ──────────────────────
  # Sugar over setProvider / replaceProvider for class-method providers. MT is
  # always async; the trampoline carries the provider proc type's `{.async.}`
  # pragma. Owning-thread semantics of setProvider/replaceProvider are unchanged
  # (the sugar only synthesises the closure the user would write by hand).
  block:
    let providerPragma = procTyPragma(makeProcType(returnType, @[]))
    var slots: seq[BindSlot] = @[]
    if not argSig.isNil():
      slots.add(
        BindSlot(
          params: cloneParams(argParams),
          returnType: copyNimTree(returnType),
          pragma: providerPragma,
        )
      )
    if not zeroArgSig.isNil():
      slots.add(
        BindSlot(
          params: @[], returnType: copyNimTree(returnType), pragma: providerPragma
        )
      )
    result.add(
      buildBindTemplates(
        typeIdent, "setProvider", "bindProvider", slots, awaitCall = true
      )
    )
    result.add(
      buildBindTemplates(
        typeIdent, "replaceProvider", "rebindProvider", slots, awaitCall = true
      )
    )

  # ── provideIt / reprovideIt body sugar ─────────────────────────────
  # Same surface as the single-thread lane (see request_broker.nim). Owning-
  # thread semantics of setProvider/replaceProvider are unchanged — the sugar
  # only synthesises the closure the user would write by hand, and
  # `providerBody` rejects bodies that could silently fall through to err("").
  block:
    let providerPragma = procTyPragma(makeProcType(returnType, @[]))
    let dualSlot = (not argSig.isNil()) and (not zeroArgSig.isNil())
    if not argSig.isNil():
      let slot = BindSlot(
        params: cloneParams(argParams),
        returnType: copyNimTree(returnType),
        pragma: providerPragma,
      )
      result.add(buildProvideTemplates(typeIdent, "setProvider", "provideIt", slot))
      result.add(
        buildProvideTemplates(typeIdent, "replaceProvider", "reprovideIt", slot)
      )
    if not zeroArgSig.isNil():
      let slot = BindSlot(
        params: @[], returnType: copyNimTree(returnType), pragma: providerPragma
      )
      let provideName = if dualSlot: "provideItNoArgs" else: "provideIt"
      let reprovideName = if dualSlot: "reprovideItNoArgs" else: "reprovideIt"
      result.add(buildProvideTemplates(typeIdent, "setProvider", provideName, slot))
      result.add(
        buildProvideTemplates(typeIdent, "replaceProvider", reprovideName, slot)
      )

  when defined(brokerDebug):
    writeBrokerDebug("RequestBrokerMt", typeDisplayName, result)
    when defined(brokerDebugStdout):
      echo result.repr

  return result

{.pop.}
