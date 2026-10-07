import results, ../common/protobuf

type
  PeerExchangeResponseStatusCode* {.pure.} = enum
    UNKNOWN = uint32(000)
    SUCCESS = uint32(200)
    BAD_REQUEST = uint32(400)
    BAD_RESPONSE = uint32(401)
    TOO_MANY_REQUESTS = uint32(429)
    SERVICE_UNAVAILABLE = uint32(503)
    DIAL_FAILURE = uint32(599)

  PeerExchangePeerInfo* {.proto3.} = object
    enr* {.fieldNumber: 1.}: seq[byte]
      # RLP encoded ENR: https://eips.ethereum.org/EIPS/eip-778

  PeerExchangeRequest* {.proto3.} = object
    numPeers* {.fieldNumber: 1, pint.}: uint64

  PeerExchangeResponse* {.proto3.} = object
    peerInfos* {.fieldNumber: 1.}: seq[PeerExchangePeerInfo]
    status_code* {.fieldNumber: 10, ext.}: PeerExchangeResponseStatusCode
    status_desc* {.fieldNumber: 11.}: Opt[string]

  PeerExchangeResponseStatus* =
    tuple[status_code: PeerExchangeResponseStatusCode, status_desc: Opt[string]]

  PeerExchangeRpc* {.proto3.} = object
    # Older nodes require field 1, so a response also writes an empty request.
    request* {.fieldNumber: 1.}: Opt[PeerExchangeRequest]
    response* {.fieldNumber: 2.}: PeerExchangeResponse

proc makeRequest*(T: type PeerExchangeRpc, numPeers: uint64): T =
  return T(request: Opt.some(PeerExchangeRequest(numPeers: numPeers)))

proc makeResponse*(T: type PeerExchangeRpc, peerInfos: seq[PeerExchangePeerInfo]): T =
  return T(
    request: Opt.some(PeerExchangeRequest()),
    response: PeerExchangeResponse(
      peerInfos: peerInfos, status_code: PeerExchangeResponseStatusCode.SUCCESS
    ),
  )

proc makeErrorResponse*(
    T: type PeerExchangeRpc,
    status_code: PeerExchangeResponseStatusCode,
    status_desc: Opt[string] = Opt.none(string),
): T =
  return T(
    request: Opt.some(PeerExchangeRequest()),
    response: PeerExchangeResponse(status_code: status_code, status_desc: status_desc),
  )

proc `$`*(statusCode: PeerExchangeResponseStatusCode): string =
  case statusCode
  of PeerExchangeResponseStatusCode.UNKNOWN: "UNKNOWN"
  of PeerExchangeResponseStatusCode.SUCCESS: "SUCCESS"
  of PeerExchangeResponseStatusCode.BAD_REQUEST: "BAD_REQUEST"
  of PeerExchangeResponseStatusCode.BAD_RESPONSE: "BAD_RESPONSE"
  of PeerExchangeResponseStatusCode.TOO_MANY_REQUESTS: "TOO_MANY_REQUESTS"
  of PeerExchangeResponseStatusCode.SERVICE_UNAVAILABLE: "SERVICE_UNAVAILABLE"
  of PeerExchangeResponseStatusCode.DIAL_FAILURE: "DIAL_FAILURE"

# proc `$`*(pxResponseStatus: PeerExchangeResponseStatus): string =
#   return $pxResponseStatus.status & " - " & pxResponseStatus.desc.get("")
