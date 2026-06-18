{.push raises: [].}

import std/[options, strutils], chronos
import ./[common, protocol, eligibility_canonical]

const EligibilityOutDescMinLen* = 512

type
  EligibilityVerifierCb* = proc (
      proof_hex, canonical_hex, requester_peer_id: cstring,
      out_desc: cstring, out_desc_len: csize_t, user_data: pointer
  ): cint {.cdecl, gcsafe, raises: [].}

proc defaultEligibilityDesc*(code: EligibilityStatusCode): string =
  case code
  of EligibilityStatusCode.OK:
    "ok"
  of EligibilityStatusCode.PARAMS_REJECTED:
    "params rejected"
  of EligibilityStatusCode.PROOF_INVALID:
    "proof invalid"
  of EligibilityStatusCode.STREAM_NOT_ACTIVE:
    "stream not active"

proc eligibilityCodeFromCint*(raw: cint): EligibilityStatusCode =
  if raw < 0:
    return EligibilityStatusCode.PROOF_INVALID
  case raw
  of 0:
    EligibilityStatusCode.OK
  of 1:
    EligibilityStatusCode.PARAMS_REJECTED
  of 2:
    EligibilityStatusCode.PROOF_INVALID
  of 3:
    EligibilityStatusCode.STREAM_NOT_ACTIVE
  else:
    EligibilityStatusCode.PROOF_INVALID

proc makeEligibilityWrappedHandler*(
    verifierCb: EligibilityVerifierCb,
    verifierUserData: pointer,
    innerHandler: StoreQueryRequestHandler,
    store: WakuStore,
): StoreQueryRequestHandler =
  proc (
      req: StoreQueryRequest
  ): Future[StoreQueryResult] {.async, gcsafe.} =
    if verifierCb.isNil:
      return await innerHandler(req)

    var reqClean = req
    let proofBytes =
      if req.eligibilityProof.isSome(): req.eligibilityProof.get() else: @[]
    reqClean.eligibilityProof = none(seq[byte])

    let canonicalHex = storeEligibilityCanonicalHex(reqClean)
    var proofHexStorage = ""
    let proofHexPtr: cstring =
      if proofBytes.len > 0:
        proofHexStorage = bytesToLowerHex(proofBytes)
        cstring(proofHexStorage)
      else:
        nil

    let requesterPeerId =
      if store.inboundRequestPeerId.isSome(): $store.inboundRequestPeerId.get()
      else: ""

    var outDescBuf = newString(EligibilityOutDescMinLen)
    outDescBuf.setLen(EligibilityOutDescMinLen)
    let verdictRaw = verifierCb(
      proofHexPtr,
      cstring(canonicalHex),
      cstring(requesterPeerId),
      cstring(outDescBuf),
      csize_t(EligibilityOutDescMinLen),
      verifierUserData,
    )

    let code = eligibilityCodeFromCint(verdictRaw)
    if code != EligibilityStatusCode.OK:
      var desc = outDescBuf.strip(chars = {'\0'})
      if desc.len == 0:
        desc = defaultEligibilityDesc(code)
      let res = StoreQueryResponse(
        requestId: req.requestId,
        statusCode: uint32(StatusCode.BAD_REQUEST),
        statusDesc: "BAD_REQUEST",
        eligibilityStatus: some(EligibilityStatus(code: code, desc: desc)),
      )
      return ok(res)

    return await innerHandler(req)
