import std/[json, options, strutils, tables, sugar, locks]
import chronos, results, stew/byteutils, ffi
import
  logos_delivery/waku/factory/waku,
  logos_delivery/waku/waku_core/peers,
  logos_delivery/waku/waku_store/[
    common, protocol, client, eligibility_canonical, eligibility_hooks
  ],
  ../declare_lib,
  ./store_query_json

const EligibilityOutProofHexMinLen = 4096

type
  EligibilityProviderCb* = proc (
      canonical_hex, provider_peer_id: cstring, out_proof_hex: cstring,
      out_buf_len: csize_t, user_data: pointer
  ): cint {.cdecl, gcsafe, raises: [].}

  StoreEligibilityState* = ref object
    verifierCb: EligibilityVerifierCb
    verifierUserData: pointer
    providerCb: EligibilityProviderCb
    providerUserData: pointer
    innerHandler: StoreQueryRequestHandler
    handlerWrapped: bool

export EligibilityVerifierCb

var
  storeEligibilityByCtx = initTable[pointer, StoreEligibilityState]()
  eligibilityHookLock: Lock

initLock(eligibilityHookLock)

proc getOrCreateStateUnlocked(key: pointer): StoreEligibilityState =
  result = storeEligibilityByCtx.getOrDefault(key)
  if result.isNil:
    result = StoreEligibilityState.new()
    storeEligibilityByCtx[key] = result

proc dropState*(ctx: ptr FFIContext[Waku]) =
  eligibilityHookLock.acquire()
  defer:
    eligibilityHookLock.release()
  storeEligibilityByCtx.del cast[pointer](ctx)

proc applyVerifierWrapper*(ctx: ptr FFIContext[Waku], state: StoreEligibilityState) =
  let store = ctx.myLib[].node.wakuStore
  if store.isNil:
    return
  if not state.handlerWrapped:
    state.innerHandler = store.requestHandler
    state.handlerWrapped = true
  store.requestHandler = makeEligibilityWrappedHandler(
    state.verifierCb, state.verifierUserData, state.innerHandler, store
  )

proc clearVerifierWrapper*(ctx: ptr FFIContext[Waku], state: StoreEligibilityState) =
  let store = ctx.myLib[].node.wakuStore
  if store.isNil or not state.handlerWrapped:
    return
  store.requestHandler = state.innerHandler
  state.handlerWrapped = false

proc logosdelivery_set_eligibility_verifier(
    ctx: ptr FFIContext[Waku], cb: EligibilityVerifierCb, userData: pointer
): cint {.dynlib, exportc, cdecl.} =
  initializeLibrary()
  if isNil(ctx):
    return RET_ERR
  eligibilityHookLock.acquire()
  defer:
    eligibilityHookLock.release()
  let state = getOrCreateStateUnlocked(cast[pointer](ctx))
  state.verifierCb = cb
  state.verifierUserData = userData
  if cb.isNil:
    clearVerifierWrapper(ctx, state)
  else:
    applyVerifierWrapper(ctx, state)
  RET_OK

proc logosdelivery_set_eligibility_provider(
    ctx: ptr FFIContext[Waku], cb: EligibilityProviderCb, userData: pointer
): cint {.dynlib, exportc, cdecl.} =
  initializeLibrary()
  if isNil(ctx):
    return RET_ERR
  eligibilityHookLock.acquire()
  defer:
    eligibilityHookLock.release()
  let state = getOrCreateStateUnlocked(cast[pointer](ctx))
  state.providerCb = cb
  state.providerUserData = userData
  RET_OK

proc snapshotProviderCb(ctx: ptr FFIContext[Waku]): (EligibilityProviderCb, pointer) {.
    gcsafe
.} =
  eligibilityHookLock.acquire()
  defer:
    eligibilityHookLock.release()
  {.cast(gcsafe).}:
    let state = storeEligibilityByCtx.getOrDefault(cast[pointer](ctx))
    if state.isNil:
      return (nil, nil)
    return (state.providerCb, state.providerUserData)

proc logosdelivery_store_query(
    ctx: ptr FFIContext[Waku],
    callback: FFICallBack,
    userData: pointer,
    queryJson: cstring,
    providerAddr: cstring,
) {.ffi.} =
  requireInitializedNode(ctx, "STORE_QUERY"):
    return err(errMsg)

  let jsonContentRes = catch:
    parseJson($queryJson)

  if jsonContentRes.isErr():
    return err("StoreRequest failed parsing store request: " & jsonContentRes.error.msg)

  var storeQueryRequest = storeQueryRequestFromJson(jsonContentRes.get()).valueOr:
    return err("StoreRequest invalid query: " & error)

  storeQueryRequest.eligibilityProof = none(seq[byte])

  let (providerCb, providerUserData) = snapshotProviderCb(ctx)

  let peer = peers.parsePeerInfo(($providerAddr).split(",")).valueOr:
    return err("StoreRequest failed to parse peer addr: " & $error)

  if not providerCb.isNil:
    let canonicalHex = storeEligibilityCanonicalHex(storeQueryRequest)
    var outProof = newString(EligibilityOutProofHexMinLen)
    outProof.setLen(EligibilityOutProofHexMinLen)
    let providerRc = providerCb(
      cstring(canonicalHex),
      cstring($peer.peerId),
      cstring(outProof),
      csize_t(EligibilityOutProofHexMinLen),
      providerUserData,
    )
    if providerRc < 0:
      return err("eligibility provider callback failed")

    var proofHex = outProof.strip(chars = {'\0'})
    if proofHex.startsWith("0x"):
      proofHex = proofHex[2 .. ^1]
    let proofBytes =
      try:
        proofHex.hexToSeqByte()
      except ValueError:
        return err("eligibility provider returned invalid proof hex")
    storeQueryRequest.eligibilityProof = some(proofBytes)

  let queryResponse = (
    await ctx.myLib[].node.wakuStoreClient.query(storeQueryRequest, peer)
  ).valueOr:
    return err("StoreRequest failed store query: " & $error)

  let res = $(%*(queryResponse.toHex()))
  return ok(res)

export
  logosdelivery_set_eligibility_verifier, logosdelivery_set_eligibility_provider,
  logosdelivery_store_query
