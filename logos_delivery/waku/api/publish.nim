## Waku layer API — message publish primitives used by the messaging send
## pipeline.
##
## Unlike `relay.nim`/`lightpush.nim`, these preserve the rich
## `WakuLightPushResult` (status code + description) that the send processors
## branch on for their retry decisions, and expose relay/lightpush availability
## so the messaging layer never inspects `waku.node` directly.
import logos_delivery/waku/compat/option_valueor
{.push raises: [].}

import std/options
import results, chronos

import logos_delivery/waku/waku
import
  logos_delivery/waku/[
    waku_core,
    node/waku_node,
    node/peer_manager,
    waku_relay/protocol,
    rln,
    waku_lightpush/common,
    waku_lightpush/rpc,
    waku_lightpush/client,
    waku_lightpush/callbacks,
  ]

# WakuLightPushResult, PushMessageHandler, LightPushErrorCode (common) plus the
# LightPushStatusCode `$`/`==` the send processors branch on (rpc).
export common, rpc

proc hasRelay*(self: Waku): bool =
  ## True if relay (gossipsub publishing) is mounted.
  return not self.node.wakuRelay.isNil()

proc hasLightpush*(self: Waku): bool =
  ## True if a lightpush client is mounted.
  return not self.node.wakuLightpushClient.isNil()

proc relayPushHandler*(self: Waku): PushMessageHandler =
  ## Builds the relay publish handler used by the send pipeline. Caller
  ## ensures relay is mounted. RLN proof generation is handled client-side
  ## in (legacy)lightpushPublish; this handler only validates and republishes.
  return getRelayPushHandler(self.node.wakuRelay)

proc lightpushPeerAvailable*(self: Waku, shard: PubsubTopic): bool =
  ## True if a lightpush service peer is available for `shard`.
  return self.node.peerManager.selectPeer(WakuLightPushCodec, some(shard)).isSome()

proc lightpushPublishToAny*(
    self: Waku, shard: PubsubTopic, message: WakuMessage
): Future[WakuLightPushResult] {.async.} =
  ## Selects a lightpush service peer for `shard` and publishes `message`.
  ## Returns SERVICE_NOT_AVAILABLE when no peer is available.
  let peer = self.node.peerManager.selectPeer(WakuLightPushCodec, some(shard)).valueOr:
    return lightpushResultServiceUnavailable("no lightpush peer available for shard")
  try:
    return await self.node.wakuLightpushClient.publish(some(shard), message, peer)
  except CatchableError as e:
    return lightpushResultInternalError(e.msg)
