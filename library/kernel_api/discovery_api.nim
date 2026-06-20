import logos_delivery/waku/compat/option_valueor
import std/json
import chronos, chronicles, results, strutils, libp2p/multiaddress, ffi
import
  logos_delivery/waku/factory/waku,
  logos_delivery/waku/discovery/waku_dnsdisc,
  logos_delivery/waku/discovery/waku_discv5,
  logos_delivery/waku/waku_core/peers,
  logos_delivery/waku/waku_node,
  library/declare_lib

proc retrieveBootstrapNodes(
    enrTreeUrl: string, ipDnsServer: string
): Future[Result[seq[string], string]] {.async.} =
  let dnsNameServers = @[parseIpAddress(ipDnsServer)]
  let discoveredPeers: seq[RemotePeerInfo] = (
    await retrieveDynamicBootstrapNodes(enrTreeUrl, dnsNameServers)
  ).valueOr:
    return err("failed discovering peers from DNS: " & $error)

  var multiAddresses = newSeq[string]()

  for discPeer in discoveredPeers:
    for address in discPeer.addrs:
      multiAddresses.add($address & "/p2p/" & $discPeer)

  return ok(multiAddresses)

proc updateDiscv5BootstrapNodes(nodes: string, waku: Waku): Result[void, string] =
  waku.wakuDiscv5.updateBootstrapRecords(nodes).isOkOr:
    return err("error in updateDiscv5BootstrapNodes: " & $error)
  return ok()

proc performPeerExchangeRequestTo*(
    numPeers: uint64, waku: Waku
): Future[Result[int, string]] {.async.} =
  let numPeersRecv = (await waku.node.fetchPeerExchangePeers(numPeers)).valueOr:
    return err($error)
  return ok(numPeersRecv)

proc waku_discv5_update_bootnodes(
    ctx: ptr FFIContext[LogosDelivery],
    callback: FFICallBack,
    userData: pointer,
    bootnodes: cstring,
) {.ffi.} =
  ## Updates the bootnode list used for discovering new peers via DiscoveryV5
  ## bootnodes - JSON array containing the bootnode ENRs i.e. `["enr:...", "enr:..."]`

  updateDiscv5BootstrapNodes($bootnodes, ctx.myLib[].waku).isOkOr:
    error "UPDATE_DISCV5_BOOTSTRAP_NODES failed", error = error
    return err($error)

  return ok("discovery request processed correctly")

proc waku_dns_discovery(
    ctx: ptr FFIContext[LogosDelivery],
    callback: FFICallBack,
    userData: pointer,
    enrTreeUrl: cstring,
    nameDnsServer: cstring,
    timeoutMs: cint,
) {.ffi.} =
  let nodes = (await retrieveBootstrapNodes($enrTreeUrl, $nameDnsServer)).valueOr:
    error "GET_BOOTSTRAP_NODES failed", error = error
    return err($error)

  ## returns a comma-separated string of bootstrap nodes' multiaddresses
  return ok(nodes.join(","))

proc waku_start_discv5(
    ctx: ptr FFIContext[LogosDelivery], callback: FFICallBack, userData: pointer
) {.ffi.} =
  (await ctx.myLib[].waku.wakuDiscv5.start()).isOkOr:
    error "START_DISCV5 failed", error = error
    return err("error starting discv5: " & $error)

  return ok("discv5 started correctly")

proc waku_stop_discv5(
    ctx: ptr FFIContext[LogosDelivery], callback: FFICallBack, userData: pointer
) {.ffi.} =
  await ctx.myLib[].waku.wakuDiscv5.stop()
  return ok("discv5 stopped correctly")

proc waku_peer_exchange_request(
    ctx: ptr FFIContext[LogosDelivery],
    callback: FFICallBack,
    userData: pointer,
    numPeers: uint64,
) {.ffi.} =
  let numValidPeers = (await performPeerExchangeRequestTo(numPeers, ctx.myLib[].waku)).valueOr:
    error "waku_peer_exchange_request failed", error = error
    return err("failed peer exchange: " & $error)

  return ok($numValidPeers)
