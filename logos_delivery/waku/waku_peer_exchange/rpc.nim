import std/options

type
  PeerExchangeResponseStatusCode* {.pure.} = enum
    UNKNOWN = uint32(000)
    SUCCESS = uint32(200)
    BAD_REQUEST = uint32(400)
    BAD_RESPONSE = uint32(401)
    TOO_MANY_REQUESTS = uint32(429)
    SERVICE_UNAVAILABLE = uint32(503)
    DIAL_FAILURE = uint32(599)

  PeerExchangePeerInfo* = object
    enr*: seq[byte] # RLP encoded ENR: https://eips.ethereum.org/EIPS/eip-778

  PeerExchangeRequest* = object
    numPeers*: uint64

  PeerExchangeResponse* = object
    peerInfos*: seq[PeerExchangePeerInfo]
    status_code*: PeerExchangeResponseStatusCode
    status_desc*: Option[string]

  PeerExchangeResponseStatus* =
    tuple[status_code: PeerExchangeResponseStatusCode, status_desc: Option[string]]

  PeerExchangeRpc* = object
    request*: PeerExchangeRequest
    response*: PeerExchangeResponse

proc makeRequest*(T: type PeerExchangeRpc, numPeers: uint64): T =
  return T(request: PeerExchangeRequest(numPeers: numPeers))

proc makeResponse*(T: type PeerExchangeRpc, peerInfos: seq[PeerExchangePeerInfo]): T =
  return T(
    response: PeerExchangeResponse(
      peerInfos: peerInfos, status_code: PeerExchangeResponseStatusCode.SUCCESS
    )
  )

proc makeErrorResponse*(
    T: type PeerExchangeRpc,
    status_code: PeerExchangeResponseStatusCode,
    status_desc: Option[string] = none(string),
): T =
  return T(
    response: PeerExchangeResponse(status_code: status_code, status_desc: status_desc)
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
