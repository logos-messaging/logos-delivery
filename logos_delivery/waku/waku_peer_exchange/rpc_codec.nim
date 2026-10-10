{.push raises: [].}

import results, ../common/protobuf, ./rpc

proc validateDecoded(rpc: var PeerExchangeRpc): ProtobufResult[void] =
  # An older peer writes no status code, and proto3 reads it as `UNKNOWN`. No
  # peer writes `UNKNOWN`, so the code follows from the peers, as on older nodes.
  if rpc.response.status_code == PeerExchangeResponseStatusCode.UNKNOWN:
    rpc.response.status_code =
      if rpc.response.peerInfos.len > 0:
        PeerExchangeResponseStatusCode.SUCCESS
      else:
        PeerExchangeResponseStatusCode.SERVICE_UNAVAILABLE
  ok()

protobufCodec(PeerExchangeRpc, validateDecoded)
