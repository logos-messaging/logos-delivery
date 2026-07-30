import std/strutils
import chronos, chronicles, results, ffi
import logos_delivery, library/declare_lib

proc waku_discv5_update_bootnodes(
    self: LogosDelivery, bootnodes: string
): Future[Result[string, string]] {.ffi.} =
  ## Updates the bootnode list used for discovering new peers via DiscoveryV5
  ## bootnodes - JSON array containing the bootnode ENRs i.e. `["enr:...", "enr:..."]`
  (await self.waku.discv5UpdateBootnodes(bootnodes)).isOkOr:
    error "UPDATE_DISCV5_BOOTSTRAP_NODES failed", error = error
    return err(error)
  return ok("discovery request processed correctly")

proc waku_dns_discovery(
    self: LogosDelivery, enrTreeUrl: string, nameDnsServer: string, timeoutMs: int32
): Future[Result[string, string]] {.ffi.} =
  ## returns a comma-separated string of bootstrap nodes' multiaddresses
  let nodes = (await self.waku.dnsDiscovery(enrTreeUrl, nameDnsServer, int(timeoutMs))).valueOr:
    error "GET_BOOTSTRAP_NODES failed", error = error
    return err(error)
  return ok(nodes.join(","))

proc waku_start_discv5(self: LogosDelivery): Future[Result[string, string]] {.ffi.} =
  (await self.waku.startDiscv5()).isOkOr:
    error "START_DISCV5 failed", error = error
    return err(error)
  return ok("discv5 started correctly")

proc waku_stop_discv5(self: LogosDelivery): Future[Result[string, string]] {.ffi.} =
  (await self.waku.stopDiscv5()).isOkOr:
    error "STOP_DISCV5 failed", error = error
    return err(error)
  return ok("discv5 stopped correctly")

proc waku_peer_exchange_request(
    self: LogosDelivery, numPeers: uint64
): Future[Result[string, string]] {.ffi.} =
  let numValidPeers = (await self.waku.peerExchangeRequest(numPeers)).valueOr:
    error "waku_peer_exchange_request failed", error = error
    return err(error)
  return ok($numValidPeers)
