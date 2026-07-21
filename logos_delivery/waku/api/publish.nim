## Waku layer API — message publish primitives used by the messaging send
## pipeline.
##
## Unlike `relay.nim`/`lightpush.nim`, these preserve the rich
## `WakuLightPushResult` (status code + description) that the send processors
## branch on for their retry decisions, and expose relay/lightpush availability
## so the messaging layer never inspects `waku.node` directly.
{.push raises: [].}

import results, chronos

import logos_delivery/waku/waku
import
  logos_delivery/waku/[
    waku_core,
    node/waku_node,
    node/waku_node/lightpush,
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

proc currentRlnEpochQuota*(self: Waku): Opt[tuple[epochIndex, messageLimit: uint64]] =
  ## RLN's current epoch index and the epoch's user message limit, read
  ## together so the pair cannot straddle an epoch boundary. `none` when RLN is
  ## not mounted (or its limit is unset) — which the rate limit manager reads as
  ## "fall back to the wall-clock window and the configured limit".
  if self.node.rln.isNil():
    return Opt.none(tuple[epochIndex, messageLimit: uint64])

  let limit = self.node.rln.groupManager.userMessageLimit.valueOr:
    return Opt.none(tuple[epochIndex, messageLimit: uint64])

  return Opt.some((fromEpoch(self.node.rln.getCurrentEpoch()), uint64(limit)))

proc lightpushPeerAvailable*(self: Waku, shard: PubsubTopic): bool =
  ## True if a lightpush service peer is available for `shard`.
  return self.node.peerManager.selectPeer(WakuLightPushCodec, Opt.some(shard)).isSome()

proc lightpushPublishToAny*(
    self: Waku, shard: PubsubTopic, message: WakuMessage
): Future[WakuLightPushResult] {.async.} =
  ## Selects a lightpush service peer for `shard` and publishes `message`
  ## through the node's lightpush flow, which attaches an RLN proof per
  ## attempt when RLN is mounted. Returns SERVICE_NOT_AVAILABLE when no peer
  ## is available.
  let peer = self.node.peerManager.selectPeer(WakuLightPushCodec, Opt.some(shard)).valueOr:
    return lightpushResultServiceUnavailable("no lightpush peer available for shard")
  try:
    return await self.node.lightpushPublish(Opt.some(shard), message, Opt.some(peer))
  except CatchableError as e:
    return lightpushResultInternalError(e.msg)
