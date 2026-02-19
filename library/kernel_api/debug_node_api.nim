import std/json
import
  chronicles,
  chronos,
  results,
  eth/p2p/discoveryv5/enr,
  strutils,
  libp2p/peerid,
  metrics,
  ffi
import
  waku/factory/waku,
  waku/node/waku_node,
  waku/node/health_monitor,
  library/declare_lib,
  waku/waku_core/codecs

proc getMultiaddresses(node: WakuNode): seq[string] =
  return node.info().listenAddresses

proc getMetrics(): string =
  {.gcsafe.}:
    return defaultRegistry.toText() ## defaultRegistry is {.global.} in metrics module

proc waku_version(
    ctx: ptr FFIContext[Waku], callback: FFICallBack, userData: pointer
) {.ffi.} =
  return ok(WakuNodeVersionString)

proc waku_listen_addresses(
    ctx: ptr FFIContext[Waku], callback: FFICallBack, userData: pointer
) {.ffi.} =
  ## returns a comma-separated string of the listen addresses
  return ok(ctx.myLib[].node.getMultiaddresses().join(","))

proc waku_get_my_enr(
    ctx: ptr FFIContext[Waku], callback: FFICallBack, userData: pointer
) {.ffi.} =
  return ok(ctx.myLib[].node.enr.toURI())

proc waku_get_my_peerid(
    ctx: ptr FFIContext[Waku], callback: FFICallBack, userData: pointer
) {.ffi.} =
  return ok($ctx.myLib[].node.peerId())

proc waku_get_metrics(
    ctx: ptr FFIContext[Waku], callback: FFICallBack, userData: pointer
) {.ffi.} =
  return ok(getMetrics())

proc waku_is_online(
    ctx: ptr FFIContext[Waku], callback: FFICallBack, userData: pointer
) {.ffi.} =
  return ok($ctx.myLib[].healthMonitor.onlineMonitor.amIOnline())

proc waku_get_mixnode_pool_size(
    ctx: ptr FFIContext[Waku], callback: FFICallBack, userData: pointer
) {.ffi.} =
  ## Returns the number of mix nodes in the pool
  if ctx.myLib[].node.wakuMix.isNil():
    return ok("0")
  return ok($ctx.myLib[].node.getMixNodePoolSize())

proc waku_get_lightpush_peers_count(
    ctx: ptr FFIContext[Waku], callback: FFICallBack, userData: pointer
) {.ffi.} =
  ## Returns the count of all peers in peerstore supporting lightpush protocol
  let peers =
    ctx.myLib[].node.peerManager.switch.peerStore.getPeersByProtocol(WakuLightPushCodec)
  return ok($peers.len)
