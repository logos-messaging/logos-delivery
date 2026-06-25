## Waku layer API — discovery operations (DNS, discv5, peer exchange).
{.push raises: [].}

import std/[net, sequtils]
import results, chronos, chronicles

import logos_delivery/waku/waku
import
  logos_delivery/waku/[
    waku_core,
    node/waku_node,
    node/waku_node/peer_exchange,
    discovery/waku_dnsdisc,
    discovery/waku_discv5,
  ]

proc dnsDiscovery*(
    self: Waku, enrTreeUrl: string, nameServer: string, timeoutMs: int
): Future[Result[seq[string], string]] {.async.} =
  try:
    let dnsNameServers = @[parseIpAddress(nameServer)]
    let discoveredPeers = (
      await retrieveDynamicBootstrapNodes(enrTreeUrl, dnsNameServers)
    ).valueOr:
      return err("failed discovering peers from DNS: " & $error)

    var multiAddresses = newSeq[string]()
    for discPeer in discoveredPeers:
      for address in discPeer.addrs:
        multiAddresses.add($address & "/p2p/" & $discPeer)

    return ok(multiAddresses)
  except CatchableError as e:
    return err(e.msg)

proc discv5UpdateBootnodes*(
    self: Waku, bootnodes: string
): Future[Result[bool, string]] {.async.} =
  ## `bootnodes` is a JSON array of ENRs, e.g. `["enr:...", "enr:..."]`.
  try:
    if self.wakuDiscv5.isNil():
      return err("discv5 not started")
    self.wakuDiscv5.updateBootstrapRecords(bootnodes).isOkOr:
      return err("error in discv5UpdateBootnodes: " & $error)
    return ok(true)
  except CatchableError as e:
    return err(e.msg)

proc startDiscv5*(self: Waku): Future[Result[bool, string]] {.async.} =
  try:
    if self.wakuDiscv5.isNil():
      return err("discv5 not started")
    (await self.wakuDiscv5.start()).isOkOr:
      return err("error starting discv5: " & $error)
    return ok(true)
  except CatchableError as e:
    return err(e.msg)

proc stopDiscv5*(self: Waku): Future[Result[bool, string]] {.async.} =
  try:
    if self.wakuDiscv5.isNil():
      return err("discv5 not started")
    await self.wakuDiscv5.stop()
    return ok(true)
  except CatchableError as e:
    return err(e.msg)

proc peerExchangeRequest*(
    self: Waku, numPeers: uint64
): Future[Result[int, string]] {.async.} =
  try:
    let numPeersRecv = (await self.node.fetchPeerExchangePeers(numPeers)).valueOr:
      return err("failed peer exchange: " & $error)
    return ok(numPeersRecv)
  except CatchableError as e:
    return err(e.msg)
