import results, metrics, chronos
import ./rpc, ../waku_core

const
  # We add a 64kB safety buffer for protocol overhead.
  # 10x-multiplier also for safety
  DefaultMaxRpcSize* = 10 * DefaultMaxWakuMessageSize + 64 * 1024
    # TODO what is the expected size of a PX message? As currently specified, it can contain an arbitrary number of ENRs...
  MaxPeersCacheSize* = 60
  CacheRefreshInterval* = 10.minutes
  DefaultPXNumPeersReq* = 5.uint64()

# Error types (metric label values)
const
  dialFailure* = "dial_failure"
  peerNotFoundFailure* = "peer_not_found_failure"
  decodeRpcFailure* = "decode_rpc_failure"
  retrievePeersDiscv5Error* = "retrieve_peers_discv5_failure"
  pxFailure* = "px_failure"

type WakuPeerExchangeResult*[T] = Result[T, PeerExchangeResponseStatus]
