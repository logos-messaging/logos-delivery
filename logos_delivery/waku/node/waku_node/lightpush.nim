import logos_delivery/waku/compat/option_valueor
{.push raises: [].}

import
  std/[hashes, options, strutils, tables, net],
  chronos,
  chronicles,
  metrics,
  results,
  stew/byteutils,
  eth/keys,
  eth/p2p/discoveryv5/enr,
  libp2p/crypto/crypto,
  libp2p/protocols/ping,
  libp2p/protocols/pubsub/gossipsub,
  libp2p/protocols/pubsub/rpc/messages,
  libp2p/builders,
  libp2p/transports/tcptransport,
  libp2p/transports/wstransport,
  libp2p/utility,
  libp2p_mix

import
  ../waku_node,
  ../../waku_core,
  ../../waku_core/topics/sharding,
  ../../waku_lightpush_legacy/client as legacy_lightpush_client,
  ../../waku_lightpush_legacy as legacy_lightpush_protocol,
  ../../waku_lightpush/client as lightpush_client,
  ../../waku_lightpush as lightpush_protocol,
  ../peer_manager,
  ../../common/rate_limit/setting,
  ../../rln

logScope:
  topics = "waku node lightpush api"

const MountWithoutRelayError* = "cannot mount lightpush because relay is not mounted"

## Waku lightpush
proc mountLegacyLightPush*(
    node: WakuNode, rateLimit: RateLimitSetting = DefaultGlobalNonRelayRateLimit
): Future[Result[void, string]] {.async.} =
  info "mounting legacy light push"

  if node.wakuRelay.isNil():
    return err(MountWithoutRelayError)

  info "mounting legacy lightpush with relay"
  let pushHandler = legacy_lightpush_protocol.getRelayPushHandler(node.wakuRelay)

  node.wakuLegacyLightPush =
    WakuLegacyLightPush.new(node.peerManager, node.rng, pushHandler, some(rateLimit))

  if node.started:
    # Node has started already. Let's start lightpush too.
    await node.wakuLegacyLightPush.start()

  node.switch.mount(node.wakuLegacyLightPush, protocolMatcher(WakuLegacyLightPushCodec))

  info "legacy lightpush mounted successfully"
  return ok()

proc mountLegacyLightPushClient*(node: WakuNode) =
  info "mounting legacy light push client"

  if node.wakuLegacyLightpushClient.isNil():
    node.wakuLegacyLightpushClient =
      WakuLegacyLightPushClient.new(node.peerManager, node.rng)

proc legacyLightpushPublish*(
    node: WakuNode,
    pubsubTopic: Option[PubsubTopic],
    message: WakuMessage,
    peer: RemotePeerInfo,
): Future[legacy_lightpush_protocol.WakuLightPushResult[string]] {.async, gcsafe.} =
  ## Pushes a `WakuMessage` to a node which relays it further on PubSub topic.
  ## Returns whether relaying was successful or not.
  ## `WakuMessage` should contain a `contentTopic` field for light node
  ## functionality.
  if node.wakuLegacyLightpushClient.isNil() and node.wakuLegacyLightPush.isNil():
    error "failed to publish message as legacy lightpush not available"
    return err("Waku lightpush not available")

  # toRLNSignal includes the timestamp in the proof input, so the timestamp
  # must be fixed before proof generation. The downstream ensureTimestampSet
  # in the client publish becomes an idempotent no-op safety net.
  let message = ensureTimestampSet(message)

  let rln =
    if node.rln.isNil():
      none(Rln)
    else:
      some(node.rln)
  var msgWithProof = (await checkAndGenerateRLNProof(rln, message)).valueOr:
    return err("failed call checkAndGenerateRLNProof from lightpush: " & error)

  let internalPublish = proc(
      node: WakuNode,
      pubsubTopic: PubsubTopic,
      message: WakuMessage,
      peer: RemotePeerInfo,
  ): Future[legacy_lightpush_protocol.WakuLightPushResult[string]] {.async, gcsafe.} =
    let msgHash = pubsubTopic.computeMessageHash(message).to0xHex()
    if not node.wakuLegacyLightpushClient.isNil():
      notice "publishing message with legacy lightpush",
        pubsubTopic = pubsubTopic,
        contentTopic = message.contentTopic,
        target_peer_id = peer.peerId,
        msg_hash = msgHash
      return await node.wakuLegacyLightpushClient.publish(pubsubTopic, message, peer)

    if not node.wakuLegacyLightPush.isNil():
      notice "publishing message with self hosted legacy lightpush",
        pubsubTopic = pubsubTopic,
        contentTopic = message.contentTopic,
        target_peer_id = peer.peerId,
        msg_hash = msgHash
      return
        await node.wakuLegacyLightPush.handleSelfLightPushRequest(pubsubTopic, message)
  try:
    # Resolve the effective pubsub topic first (explicit param, else derive
    # from autosharding), then run the send. We need a single resolved topic
    # so the retry path below can reuse it without repeating this branch.
    var pubsubForPublish: PubsubTopic
    if pubsubTopic.isSome():
      pubsubForPublish = pubsubTopic.get()
    else:
      if node.wakuAutoSharding.isNone():
        return err("Pubsub topic must be specified when static sharding is enabled")
      let topicMap =
        ?node.wakuAutoSharding.get().getShardsFromContentTopics(message.contentTopic)
      var resolved = false
      for pubsub, _ in topicMap.pairs: # There's only one pair anyway
        pubsubForPublish = $pubsub
        resolved = true
        break
      if not resolved:
        # Preserve pre-existing behavior: an empty topicMap fell off the end
        # of the loop and returned the default-initialized Result.
        return

    let firstResult = await internalPublish(node, pubsubForPublish, msgWithProof, peer)

    # Legacy protocol has no status code taxonomy: the server collapses every
    # failure into isSuccess=false + a free-text info string. The only stable
    # substring we can safely branch on is "RLN validation failed" — the
    # errorMessage registered for the RLN validator in waku_node/relay.nim.
    # Match it and treat it as the legacy equivalent of a v3 420/504: force
    # refresh the cached merkle path, regenerate the RLN proof, and retry the
    # send exactly once. All other failure modes (decode error, rate limit,
    # no peers) are surfaced to the caller unchanged because a fresh proof
    # would not change their outcome.
    if firstResult.isOk() or rln.isNone() or
        not firstResult.error.contains("RLN validation failed"):
      return firstResult

    info "legacy lightpush send rejected as RLN-invalid; " &
      "refreshing merkle proof and retrying once"
    msgWithProof = (
      await checkAndGenerateRLNProof(rln, msgWithProof, forceMerkleProofRefresh = true)
    ).valueOr:
      return err(
        "failed call checkAndGenerateRLNProof from lightpush retry: " & error
      )

    return await internalPublish(node, pubsubForPublish, msgWithProof, peer)
  except CatchableError:
    return err(getCurrentExceptionMsg())

# TODO: Move to application module (e.g., wakunode2.nim)
proc legacyLightpushPublish*(
    node: WakuNode, pubsubTopic: Option[PubsubTopic], message: WakuMessage
): Future[legacy_lightpush_protocol.WakuLightPushResult[string]] {.
    async, gcsafe, deprecated: "Use 'node.legacyLightpushPublish()' instead"
.} =
  if node.wakuLegacyLightpushClient.isNil() and node.wakuLegacyLightPush.isNil():
    error "failed to publish message as legacy lightpush not available"
    return err("waku legacy lightpush not available")

  var peerOpt: Option[RemotePeerInfo] = none(RemotePeerInfo)
  if not node.wakuLegacyLightpushClient.isNil():
    peerOpt = node.peerManager.selectPeer(WakuLegacyLightPushCodec)
    if peerOpt.isNone():
      let msg = "no suitable remote peers"
      error "failed to publish message", err = msg
      return err(msg)
  elif not node.wakuLegacyLightPush.isNil():
    peerOpt = some(RemotePeerInfo.init($node.switch.peerInfo.peerId))

  return await node.legacyLightpushPublish(pubsubTopic, message, peer = peerOpt.get())

proc mountLightPush*(
    node: WakuNode, rateLimit: RateLimitSetting = DefaultGlobalNonRelayRateLimit
): Future[Result[void, string]] {.async.} =
  info "mounting light push"

  if node.wakuRelay.isNil():
    return err(MountWithoutRelayError)

  info "mounting lightpush with relay"
  let pushHandler = lightpush_protocol.getRelayPushHandler(node.wakuRelay)

  node.wakuLightPush = WakuLightPush.new(
    node.peerManager, node.rng, pushHandler, node.wakuAutoSharding, some(rateLimit)
  )

  if node.started:
    # Node has started already. Let's start lightpush too.
    await node.wakuLightPush.start()

  node.switch.mount(node.wakuLightPush, protocolMatcher(WakuLightPushCodec))

  info "lightpush mounted successfully"
  return ok()

proc mountLightPushClient*(node: WakuNode) =
  info "mounting light push client"

  if node.wakuLightpushClient.isNil():
    node.wakuLightpushClient = WakuLightPushClient.new(node.peerManager, node.rng)

proc lightpushPublishHandler(
    node: WakuNode,
    pubsubTopic: PubsubTopic,
    message: WakuMessage,
    peer: RemotePeerInfo | PeerInfo,
    mixify: bool = false,
): Future[lightpush_protocol.WakuLightPushResult] {.async.} =
  let msgHash = pubsubTopic.computeMessageHash(message).to0xHex()
  if not node.wakuLightpushClient.isNil():
    notice "publishing message with lightpush",
      pubsubTopic = pubsubTopic,
      contentTopic = message.contentTopic,
      target_peer_id = peer.peerId,
      msg_hash = msgHash,
      mixify = mixify
    if defined(libp2p_mix_experimental_exit_is_dest) and mixify:
      #indicates we want to use mix to send the message
      when defined(libp2p_mix_experimental_exit_is_dest):
        #TODO: How to handle multiple addresses?
        let conn = node.wakuMix.toConnection(
          MixDestination.exitNode(peer.peerId),
          WakuLightPushCodec,
          MixParameters(expectReply: Opt.some(true), numSurbs: Opt.some(byte(1))),
            # indicating we only want a single path to be used for reply hence numSurbs = 1
        ).valueOr:
          error "could not create mix connection"
          return lighpushErrorResult(
            LightPushErrorCode.SERVICE_NOT_AVAILABLE,
            "Waku lightpush with mix not available",
          )

        return await node.wakuLightpushClient.publish(some(pubsubTopic), message, conn)
    else:
      return await node.wakuLightpushClient.publish(some(pubsubTopic), message, peer)

  if not node.wakuLightPush.isNil():
    if mixify:
      error "mixify is not supported with self hosted lightpush"
      return lighpushErrorResult(
        LightPushErrorCode.SERVICE_NOT_AVAILABLE,
        "Waku lightpush with mix not available",
      )
    notice "publishing message with self hosted lightpush",
      pubsubTopic = pubsubTopic,
      contentTopic = message.contentTopic,
      target_peer_id = peer.peerId,
      msg_hash = msgHash
    return
      await node.wakuLightPush.handleSelfLightPushRequest(some(pubsubTopic), message)

proc lightpushPublish*(
    node: WakuNode,
    pubsubTopic: Option[PubsubTopic],
    message: WakuMessage,
    peerOpt: Option[RemotePeerInfo] = none(RemotePeerInfo),
    mixify: bool = false,
): Future[lightpush_protocol.WakuLightPushResult] {.async.} =
  if node.wakuLightpushClient.isNil() and node.wakuLightPush.isNil():
    error "failed to publish message as lightpush not available"
    return lighpushErrorResult(
      LightPushErrorCode.SERVICE_NOT_AVAILABLE, "Waku lightpush not available"
    )
  if mixify and node.wakuMix.isNil():
    error "failed to publish message using mix as mix protocol is not mounted"
    return lighpushErrorResult(
      LightPushErrorCode.SERVICE_NOT_AVAILABLE, "Waku lightpush with mix not available"
    )
  let toPeer: RemotePeerInfo = peerOpt.valueOr:
    if not node.wakuLightPush.isNil():
      RemotePeerInfo.init(node.peerId())
    elif not node.wakuLightpushClient.isNil():
      node.peerManager.selectPeer(WakuLightPushCodec).valueOr:
        let msg = "no suitable remote peers"
        error "failed to publish message", msg = msg
        return lighpushErrorResult(LightPushErrorCode.NO_PEERS_TO_RELAY, msg)
    else:
      return lighpushErrorResult(
        LightPushErrorCode.NO_PEERS_TO_RELAY, "no suitable remote peers"
      )

  let pubsubForPublish = pubsubTopic.valueOr:
    if node.wakuAutoSharding.isNone():
      let msg = "Pubsub topic must be specified when static sharding is enabled"
      error "lightpush publish error", error = msg
      return lighpushErrorResult(LightPushErrorCode.INVALID_MESSAGE, msg)

    let parsedTopic = NsContentTopic.parse(message.contentTopic).valueOr:
      let msg = "Invalid content-topic:" & $error
      error "lightpush request handling error", error = msg
      return lighpushErrorResult(LightPushErrorCode.INVALID_MESSAGE, msg)

    node.wakuAutoSharding.get().getShard(parsedTopic).valueOr:
      let msg = "Autosharding error: " & error
      error "lightpush publish error", error = msg
      return lighpushErrorResult(LightPushErrorCode.INTERNAL_SERVER_ERROR, msg)

  # toRLNSignal includes the timestamp in the proof input, so the timestamp
  # must be fixed before proof generation. The downstream ensureTimestampSet
  # in the client publish becomes an idempotent no-op safety net.
  let message = ensureTimestampSet(message)

  let rln =
    if node.rln.isNil():
      none(Rln)
    else:
      some(node.rln)
  var msgWithProof = (await checkAndGenerateRLNProof(rln, message)).valueOr:
    return lighpushErrorResult(LightPushErrorCode.OUT_OF_RLN_PROOF, error)

  let firstResult =
    await lightpushPublishHandler(node, pubsubForPublish, msgWithProof, toPeer, mixify)

  # If message is rejected with error code 420 (INVALID_MESSAGE) or 504 
  # (OUT_OF_RLN_PROOF) then cached merkle path is likely stale relative
  # to the current on-chain group. Force-refresh it, regenerate the proof,
  # and retry the send exactly once.
  if firstResult.isOk() or rln.isNone() or
      firstResult.error.code notin
      [LightPushErrorCode.INVALID_MESSAGE, LightPushErrorCode.OUT_OF_RLN_PROOF]:
    return firstResult

  info "lightpush send rejected; refreshing merkle proof and retrying once",
    statusCode = $firstResult.error.code
  msgWithProof = (
    await checkAndGenerateRLNProof(rln, msgWithProof, forceMerkleProofRefresh = true)
  ).valueOr:
    return lighpushErrorResult(LightPushErrorCode.OUT_OF_RLN_PROOF, error)

  return
    await lightpushPublishHandler(node, pubsubForPublish, msgWithProof, toPeer, mixify)
