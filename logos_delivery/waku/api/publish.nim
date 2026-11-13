## Waku layer API — message publish primitives used by the messaging send
## pipeline.
##
## Unlike `relay.nim`/`lightpush.nim`, these preserve the rich
## `WakuLightPushResult` (status code + description) that the send transports
## branch on for their retry decisions, and expose relay/lightpush availability
## so the messaging layer never inspects `waku.node` directly.
{.push raises: [].}

import std/[tables, strutils]
import results, chronos, libp2p/crypto/rng, libp2p_mix/pool

import logos_delivery/waku/waku
import
  logos_delivery/waku/[
    waku_core,
    node/waku_node,
    rln/rln_api,
    rln/rln_plugin,
    node/waku_node/lightpush,
    node/peer_manager,
    rln,
    waku_relay/protocol,
    waku_lightpush/common,
    waku_lightpush/rpc,
    waku_lightpush/callbacks,
    waku_mix,
  ]

# WakuLightPushResult, PushMessageHandler, LightPushErrorCode (common) plus the
# LightPushStatusCode `$`/`==` the send transports branch on (rpc).
export common, rpc

proc hasRelay*(self: Waku): bool =
  ## True if relay (gossipsub publishing) is mounted.
  return not self.node.wakuRelay.isNil()

proc hasLightpush*(self: Waku): bool =
  ## True if a lightpush client is mounted.
  return not self.node.wakuLightpushClient.isNil()

proc relayPushHandler*(self: Waku): PushMessageHandler =
  ## Builds the relay publish handler used by the send pipeline. Caller
  ## ensures relay is mounted. The handler validates and republishes; the
  ## proof is attached by the messaging layer via `attachRlnProof`.
  return getRelayPushHandler(self.node.wakuRelay)

proc relayRepublish*(
    self: Waku, shard: PubsubTopic, message: WakuMessage
): Future[WakuLightPushResult] {.async.} =
  ## Publishes over relay a message that the relay of this node already validated.
  ## It runs no validator, because the RLN validator refuses a proof that it
  ## already has.
  let relay = self.node.wakuRelay
  let peerCount = (await protocol.publish(relay, shard, message)).valueOr:
    return mapPubishingErrorToPushResult(error, relay.maxEncodedMessageSize)
  return lightpushSuccessResult(peerCount.uint32)

proc rlnEpochQuota*(
    self: Waku, timestamp: uint64
): Future[Result[EpochQuota, RlnError]] {.async.} =
  ## The mounted RLN backend's budget snapshot for the epoch derived from
  ## `timestamp` (Unix seconds). An error without a backend that keeps one.
  return await epochQuota(self.node.rlnPlugin, timestamp)

proc rlnEpochSizeSec*(self: Waku): Opt[uint64] =
  let plugin = self.node.rlnPlugin.valueOr:
    return Opt.none(uint64)
  return plugin.epochSizeSec

proc attachRlnProof*(
    self: Waku, message: WakuMessage
): Future[Result[WakuMessage, RlnError]] {.async.} =
  ## Returns `message` carrying an RLN proof. A message that already has one is
  ## returned untouched, so retrying a task neither redraws a nonce nor changes
  ## the bytes. Without RLN mounted the message passes through unproven. The
  ## error's kind tells the caller whether a retry can succeed.
  return await attachProof(self.node.rlnPlugin, message)

func needsRlnProof*(self: Waku, message: WakuMessage): bool =
  ## True when `attachRlnProof` makes a proof for `message` and reserves an RLN
  ## message id.
  return self.node.rlnPlugin.needsProof(message)

func maxMessageSizeBytes*(self: Waku): uint64 =
  return self.conf.maxMessageSizeBytes

proc messageForSizeCheck*(
    self: Waku, message: WakuMessage
): Result[WakuMessage, RlnError] =
  return self.node.rlnPlugin.messageForSizeCheck(message)

func isRlnRejection*(error: ErrorStatus): bool =
  ## True when a publish failure means "the RLN proof was not accepted", so the
  ## message is worth retrying with a freshly generated proof rather than being
  ## failed outright.
  ##
  ## OUT_OF_RLN_PROOF is always RLN. INVALID_MESSAGE also covers non-RLN
  ## rejections (an oversized message, say), so it additionally has to carry the
  ## validator's error marker — this is the same gate the kernel lightpush path
  ## applies before scheduling a refresh.
  return
    error.code == LightPushErrorCode.OUT_OF_RLN_PROOF or (
      error.code == LightPushErrorCode.INVALID_MESSAGE and
      error.desc.get("").contains(RlnValidatorErrorMsg)
    )

proc onRlnProofRejected*(self: Waku): bool =
  ## Tells the mounted RLN backend its proof was rejected. True when the
  ## backend will refresh what proofs are built against; see
  ## `notifyProofRejected`.
  return self.node.rlnPlugin.notifyProofRejected()

proc lightpushPeerAvailable*(self: Waku, shard: PubsubTopic): bool =
  ## True if a lightpush service peer is available for `shard`.
  return self.node.peerManager.selectPeer(WakuLightPushCodec, Opt.some(shard)).isSome()

proc selectLightpushPeer*(
    self: Waku, shard: PubsubTopic, tried: openArray[PeerId]
): Opt[RemotePeerInfo] =
  ## The lightpush service peer that `lightpushPublishToAny` selects for `shard`.
  ## When that peer is in `tried`, a peer outside `tried`, if the node knows one.
  let preferred = self.node.peerManager.selectPeer(WakuLightPushCodec, Opt.some(shard))
  if preferred.isNone() or preferred.get().peerId notin tried:
    return preferred
  for peer in self.node.peerManager.selectPeers(WakuLightPushCodec, Opt.some(shard)):
    if peer.peerId notin tried:
      return Opt.some(peer)
  return preferred

proc selectMixLightpushPeer*(self: Waku, shard: PubsubTopic): Opt[RemotePeerInfo] =
  ## Selects a lightpush service peer for `shard` that mix can route to. With
  ## `exit_is_dest` the server is the last node of the sphinx path, so the mix
  ## pool must hold a `MixPubInfo` for it. The selection reads the service slot
  ## first, then draws one usable pool member uniformly.
  let peerStore = self.node.peerManager.switch.peerStore
  let pool = MixNodePool.new(peerStore)

  let slotted = self.node.peerManager.serviceSlots.getOrDefault(WakuLightPushCodec)
  if not slotted.isNil() and pool.get(slotted.peerId).isSome():
    return Opt.some(peerStore.getPeer(slotted.peerId))

  let shardInfo = RelayShard.parse(shard).valueOr:
    return Opt.none(RemotePeerInfo)

  var exits: seq[PeerId]
  for peerId in pool.peerIds():
    if not peerStore[ProtoBook][peerId].contains(WakuLightPushCodec):
      continue
    if not peerStore.hasShard(peerId, shardInfo.clusterId, shardInfo.shardId):
      continue
    if pool.get(peerId).isSome():
      exits.add(peerId)

  # The exit choice must not be predictable, so draw it from the node's CSPRNG,
  # as the mix delay strategy and the mix library's hop selection do. `pickOne`
  # is rejection-sampled and uniform.
  let exit = self.rng.pickOne(exits).valueOr:
    return Opt.none(RemotePeerInfo)
  return Opt.some(peerStore.getPeer(exit))

proc mixReady*(self: Waku): bool =
  ## True when mix is mounted, mix can encode this node's own hop, and the pool
  ## has enough nodes for a path. `lightpushPublishToAny` selects the exit and
  ## reports SERVICE_NOT_AVAILABLE when it finds none.
  if self.node.wakuMix.isNil():
    return false
  if not self.node.wakuMix.selfHopUsable():
    return false
  return self.node.getMixNodePoolSize() >= MinMixPoolSize

proc mixMounted*(self: Waku): bool =
  ## True when mix is mounted. A short pool or a missing exit can clear with
  ## time; a node without mix never sends over mix.
  return not self.node.wakuMix.isNil()

proc mixSelfHopUsable*(self: Waku): bool =
  ## True when mix is mounted and can encode this node's own hop. `mixReady`
  ## also checks this; the send path reads it alone to name the reason.
  return not self.node.wakuMix.isNil() and self.node.wakuMix.selfHopUsable()

proc mixLightpushSize*(
    self: Waku, shard: PubsubTopic, message: WakuMessage
): tuple[size, limit: int] =
  ## The bytes of a lightpush request over mix for `message`, and the limit of
  ## one mix message.
  return lightpush.mixLightpushSize(shard, message)

proc lightpushPublishTo*(
    self: Waku,
    shard: PubsubTopic,
    message: WakuMessage,
    peer: RemotePeerInfo,
    mixify: bool = false,
): Future[WakuLightPushResult] {.async.} =
  ## Publishes `message` through the lightpush service peer `peer`, with the
  ## node's lightpush flow. With RLN mounted the flow proves `message` only if it
  ## carries no proof, so an already-proven task reuses its nonce.
  try:
    return
      await self.node.lightpushPublish(Opt.some(shard), message, Opt.some(peer), mixify)
  except CancelledError as exc:
    # The send service cancels an attempt at its timeout and at its stop.
    raise exc
  except CatchableError as e:
    return lightpushResultInternalError(e.msg)

proc lightpushPublishToAny*(
    self: Waku, shard: PubsubTopic, message: WakuMessage, mixify: bool = false
): Future[WakuLightPushResult] {.async.} =
  ## Selects a lightpush service peer for `shard` and publishes `message` through
  ## it. Returns SERVICE_NOT_AVAILABLE when no peer is available.
  let peerOpt =
    if mixify:
      self.selectMixLightpushPeer(shard)
    else:
      self.node.peerManager.selectPeer(WakuLightPushCodec, Opt.some(shard))
  let peer = peerOpt.valueOr:
    if mixify:
      return lightpushResultServiceUnavailable(
        "no mix-capable lightpush peer available for shard"
      )
    return lightpushResultServiceUnavailable("no lightpush peer available for shard")
  return await self.lightpushPublishTo(shard, message, peer, mixify)
