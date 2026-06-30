import std/strutils
import chronos, chronicles, results, ffi
import logos_delivery, library/declare_lib

proc waku_discv5_update_bootnodes(
    ctx: ptr FFIContext[LogosDelivery],
    callback: FFICallBack,
    userData: pointer,
    bootnodes: cstring,
) {.ffi.} =
  ## Updates the bootnode list used for discovering new peers via DiscoveryV5
  ## bootnodes - JSON array containing the bootnode ENRs i.e. `["enr:...", "enr:..."]`
  (await ctx.myLib[].waku.discv5UpdateBootnodes($bootnodes)).isOkOr:
    error "UPDATE_DISCV5_BOOTSTRAP_NODES failed", error = error
    return err(error)
  return ok("discovery request processed correctly")

proc waku_dns_discovery(
    ctx: ptr FFIContext[LogosDelivery],
    callback: FFICallBack,
    userData: pointer,
    enrTreeUrl: cstring,
    nameDnsServer: cstring,
    timeoutMs: cint,
) {.ffi.} =
  let nodes = (
    await ctx.myLib[].waku.dnsDiscovery($enrTreeUrl, $nameDnsServer, int(timeoutMs))
  ).valueOr:
    error "GET_BOOTSTRAP_NODES failed", error = error
    return err(error)
  ## returns a comma-separated string of bootstrap nodes' multiaddresses
  return ok(nodes.join(","))

proc waku_start_discv5(
    ctx: ptr FFIContext[LogosDelivery], callback: FFICallBack, userData: pointer
) {.ffi.} =
  (await ctx.myLib[].waku.startDiscv5()).isOkOr:
    error "START_DISCV5 failed", error = error
    return err(error)
  return ok("discv5 started correctly")

proc waku_stop_discv5(
    ctx: ptr FFIContext[LogosDelivery], callback: FFICallBack, userData: pointer
) {.ffi.} =
  (await ctx.myLib[].waku.stopDiscv5()).isOkOr:
    error "STOP_DISCV5 failed", error = error
    return err(error)
  return ok("discv5 stopped correctly")

proc waku_peer_exchange_request(
    ctx: ptr FFIContext[LogosDelivery],
    callback: FFICallBack,
    userData: pointer,
    numPeers: uint64,
) {.ffi.} =
  let numValidPeers = (await ctx.myLib[].waku.peerExchangeRequest(numPeers)).valueOr:
    error "waku_peer_exchange_request failed", error = error
    return err(error)
  return ok($numValidPeers)
