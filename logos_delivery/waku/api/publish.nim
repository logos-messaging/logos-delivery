## Waku layer API — message publish primitives used by the messaging send
## pipeline.
##
## Unlike `relay.nim`/`lightpush.nim`, these preserve the rich
## `WakuLightPushResult` (status code + description) that the send processors
## branch on for their retry decisions, and expose relay/lightpush availability
## so the messaging layer never inspects `waku.node` directly.
{.push raises: [].}

import std/[tables, times, strutils]
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
    waku_mix,
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
  ## ensures relay is mounted. The handler validates and republishes; the
  ## proof is attached by the messaging layer via `attachRlnProof`.
  return getRelayPushHandler(self.node.wakuRelay)

proc currentRlnEpochQuota*(self: Waku): Opt[tuple[epochIndex, messageLimit: uint64]] =
  ## RLN's current epoch index and user message limit, read together so the
  ## pair cannot straddle an epoch boundary.
  if self.node.rln.isNil():
    return Opt.none(tuple[epochIndex, messageLimit: uint64])

  let limit = self.node.rln.groupManager.userMessageLimit.valueOr:
    return Opt.none(tuple[epochIndex, messageLimit: uint64])

  return Opt.some((fromEpoch(self.node.rln.getCurrentEpoch()), uint64(limit)))

proc attachRlnProof*(
    self: Waku, message: WakuMessage
): Future[Result[WakuMessage, string]] {.async.} =
  ## Returns `message` carrying an RLN proof. A message that already has one is
  ## returned untouched, so retrying a task neither redraws a nonce nor changes
  ## the bytes. Without RLN mounted the message passes through unproven.
  ##
  ## Uses the root-refreshing generator: a message can wait in the send
  ## service's task cache while the group root moves on chain, so the proof is
  ## validated against the acceptable-root window and regenerated once against a
  ## refetched merkle path if it went stale.
  if self.node.rln.isNil() or message.proof.len > 0:
    return ok(message)

  var msgWithProof = message
  msgWithProof.proof = (
    await self.node.rln.generateRLNProofWithRootRefresh(
      message.toRLNSignal(), float64(getTime().toUnix())
    )
  ).valueOr:
    return err("failed to attach RLN proof: " & error)

  return ok(msgWithProof)

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

proc onRlnProofRejected*(self: Waku) =
  ## Called when a publish was rejected as RLN-invalid. Starts refetching the
  ## merkle path in the background, so the next proof generated for the message
  ## is built against a fresh one. Non-blocking: the send service's own loop is
  ## what retries, and it must not stall waiting on an RPC round trip.
  if self.node.rln.isNil():
    return

  self.node.rln.groupManager.scheduleMerkleProofRefresh()

proc lightpushPeerAvailable*(self: Waku, shard: PubsubTopic): bool =
  ## True if a lightpush service peer is available for `shard`.
  return self.node.peerManager.selectPeer(WakuLightPushCodec, Opt.some(shard)).isSome()

proc selectMixLightpushPeer*(self: Waku, shard: PubsubTopic): Opt[RemotePeerInfo] =
  ## Picks a lightpush service peer for `shard` that mix can route to. With
  ## `exit_is_dest` the lightpush server terminates the sphinx path, so it has
  ## to be a member of mix's node pool: a peer that serves lightpush but is not
  ## in the pool is unusable here.
  ##
  ## Membership is asked of the peer store, because that is where the pool
  ## lives: `MixNodePool` is a view over `MixPubKeyBook`, which discovery
  ## (kademlia, rendezvous) and the static `--mixnode` list both write to. So
  ## the pool needs no separate feeding, and this needs no separate bookkeeping.
  ##
  ## Follows `selectPeer`'s service-slot-first order on purpose. A statically
  ## configured `--lightpushnode` lives in the slot and is invisible to
  ## `selectPeers`: it enters the peer store from a bare multiaddr, with no
  ## protocols and no shards, so both of that proc's filters drop it until
  ## identify and waku-metadata have filled those books. Selecting only from
  ## `selectPeers` would leave `mixReady` false on exactly the setup a mix
  ## deployment uses.
  let peerStore = self.node.peerManager.switch.peerStore
  let slotted = self.node.peerManager.serviceSlots.getOrDefault(WakuLightPushCodec)
  if not slotted.isNil() and peerStore.isUsableMixNode(slotted.peerId):
    return Opt.some(peerStore.getPeer(slotted.peerId))

  for peer in self.node.peerManager.selectPeers(WakuLightPushCodec, Opt.some(shard)):
    if peerStore.isUsableMixNode(peer.peerId):
      return Opt.some(peer)
  return Opt.none(RemotePeerInfo)

proc mixReady*(self: Waku, shard: PubsubTopic): bool =
  ## True if mix can carry a publish for `shard` right now: mounted, enough
  ## nodes in the pool to build a path, and a mix-capable exit to send to.
  if self.node.wakuMix.isNil():
    return false
  if self.node.getMixNodePoolSize() < MinMixPoolSize:
    return false
  return self.selectMixLightpushPeer(shard).isSome()

proc lightpushPublishToAny*(
    self: Waku, shard: PubsubTopic, message: WakuMessage, mixify: bool = false
): Future[WakuLightPushResult] {.async.} =
  ## Selects a lightpush service peer for `shard` and publishes `message`
  ## through the node's lightpush flow. With RLN mounted the flow proves
  ## `message` only if it carries no proof, so an already-proven task reuses its
  ## nonce. Returns SERVICE_NOT_AVAILABLE when no peer is available.
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
  try:
    return
      await self.node.lightpushPublish(Opt.some(shard), message, Opt.some(peer), mixify)
  except CatchableError as e:
    return lightpushResultInternalError(e.msg)
