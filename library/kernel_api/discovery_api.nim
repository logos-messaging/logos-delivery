proc discv5_update_bootnodes*(
    self: LogosDelivery, bootnodes: string
): Future[Result[string, string]] {.ffi.} =
  ## `bootnodes` is a JSON array of ENRs, e.g. `["enr:...", "enr:..."]`.
  (await self.waku.discv5UpdateBootnodes(bootnodes)).isOkOr:
    return err(error)
  return ok("")

proc dns_discovery*(
    self: LogosDelivery, enrTreeUrl: string, nameDnsServer: string, timeoutMs: int
): Future[Result[string, string]] {.ffi.} =
  let nodes = (await self.waku.dnsDiscovery(enrTreeUrl, nameDnsServer, timeoutMs)).valueOr:
    return err(error)
  return ok(nodes.join(","))

proc start_discv5*(self: LogosDelivery): Future[Result[string, string]] {.ffi.} =
  (await self.waku.startDiscv5()).isOkOr:
    return err(error)
  return ok("")

proc stop_discv5*(self: LogosDelivery): Future[Result[string, string]] {.ffi.} =
  (await self.waku.stopDiscv5()).isOkOr:
    return err(error)
  return ok("")

proc peer_exchange_request*(
    self: LogosDelivery, numPeers: uint64
): Future[Result[string, string]] {.ffi.} =
  let n = (await self.waku.peerExchangeRequest(numPeers)).valueOr:
    return err(error)
  return ok($n)
