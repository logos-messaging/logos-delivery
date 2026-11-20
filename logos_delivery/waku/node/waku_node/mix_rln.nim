{.push raises: [].}
import std/json
import chronos, chronicles, results
import mix_rln_spam_protection/module_api
import logos_delivery/api/events/kernel_events
import
  logos_delivery/waku/[
    waku_core,
    node/waku_node,
    node/subscription_manager,
    rln/rln_plugin,
    rln/types,
    rln/rln_lez/transport,
  ]
import ./[relay, lightpush]

proc readMixMembership*(
    plugin: ModuleRlnProtection
): Future[Result[MembershipStatus, string]] {.async: (raises: [CancelledError]).} =
  ## The state of this node's membership in the Mix registry, read from the RLN
  ## module on the Mix scope. The library does not acquire the membership: the
  ## host's RLN module adopts, pays for or is granted one.
  let reply = (await plugin.scopedCall("get_membership_state")).valueOr:
    return err(error)
  let status = parseRlnMembershipStatus(reply{"state"}.getStr("")).valueOr:
    return err($error)
  return ok(status)

proc publishMetadata(
    node: WakuNode, topic: string, data: seq[byte]
): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
  var message = WakuMessage(
    payload: data,
    contentTopic: topic,
    timestamp: getNowInNanosecondTime(),
    ephemeral: true,
  )
  # Coordination messages use the node's mounted Relay RLN backend. Mix per-hop
  # proofs use wakuMixRln's separate scope.
  if node.rlnPlugin.isSome():
    try:
      message = (await attachProof(node.rlnPlugin, message)).valueOr:
        return err("Failed to attach Relay RLN proof: " & $error)
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      return err("Relay RLN proof generation failed: " & exc.msg)
  try:
    if not node.wakuRelay.isNil():
      let peers = (await node.publish(Opt.none(PubsubTopic), message)).valueOr:
        return err(error)
      if peers == 0:
        return err("No Relay peers for Mix coordination")
    else:
      discard (
        await node.lightpushPublish(Opt.none(PubsubTopic), message, mixify = false)
      ).valueOr:
        return err("Mix coordination Lightpush failed: " & $error)
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    return err("Mix coordination publish failed: " & exc.msg)
  return ok()

const MixMembershipPollInterval* = 30.seconds
  ## How often the node re-reads its Mix membership. A membership granted by an
  ## allocator arrives after the node asked for it, and an active one expires.

proc refreshMixMembership*(node: WakuNode) {.async: (raises: [CancelledError]).} =
  ## Re-reads the Mix membership and reports a change. An unanswered read keeps
  ## the last known answer: a backend that is slow once says nothing about the
  ## membership.
  let status = (await node.wakuMixRln.readMixMembership()).valueOr:
    debug "Mix membership check got no answer", error
    return
  let usable = status.isUsable()
  if usable == node.mixMembershipUsable:
    return
  node.mixMembershipUsable = usable
  if usable:
    info "Mix RLN membership is usable", status = $status
  else:
    notice "Mix RLN membership is no longer usable; this node cannot prove a Mix hop",
      status = $status
  node.mixAdvertChanged("mix membership")

proc watchMixMembership(node: WakuNode) {.async: (raises: [CancelledError]).} =
  while true:
    await sleepAsync(MixMembershipPollInterval)
    await node.refreshMixMembership()

proc stopMixRln*(node: WakuNode) {.async: (raises: []).} =
  if node.wakuMixRln.isNil():
    return
  if not node.mixMembershipLoop.isNil():
    await node.mixMembershipLoop.cancelAndWait()
    node.mixMembershipLoop = nil
  if node.wakuMixRlnListener.isSome():
    await MessageSeenEvent.dropListener(node.brokerCtx, node.wakuMixRlnListener.get())
  node.wakuMixRlnListener = Opt.none(MessageSeenEventListener)
  await node.wakuMixRln.stop()

proc startMixRln*(
    node: WakuNode
): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
  if node.wakuMixRln.isNil():
    return err("Mix RLN is not configured")
  if node.rlnPlugin.isNone():
    return err("Mix RLN coordination requires Relay RLN")
  let plugin = node.wakuMixRln
  plugin.setPublishCallback(
    proc(topic: string, data: seq[byte]): Future[Result[void, string]] {.async.} =
      return await node.publishMetadata(topic, data)
  )
  (await plugin.start()).isOkOr:
    return err("Failed to start Mix RLN plugin: " & $error)
  # A node without a usable Mix membership cannot prove a hop. That does not
  # stop startup: the membership can arrive later.
  let membership = await plugin.readMixMembership()
  node.mixMembershipUsable = membership.isOk() and membership.get().isUsable()
  if membership.isErr():
    warn "RLN backend did not answer the Mix membership check", error = membership.error
  elif not node.mixMembershipUsable:
    notice "No usable Mix RLN membership; this node cannot prove a Mix hop until it is active",
      status = $membership.get()
  else:
    info "Mix RLN membership verified", status = $membership.get()
  if node.mixMembershipLoop.isNil():
    node.mixMembershipLoop = node.watchMixMembership()
  if node.wakuMixRlnListener.isSome():
    return ok()
  let handler = proc(event: MessageSeenEvent): Future[void] {.async: (raises: []).} =
    if event.message.contentTopic == plugin.config.metadataTopic:
      plugin.handleProofMetadata(event.message.payload).isOkOr:
        debug "Rejected Mix coordination metadata", error
  let listener = MessageSeenEvent.listen(node.brokerCtx, handler).valueOr:
    await node.stopMixRln()
    return err(error)
  node.wakuMixRlnListener = Opt.some(listener)
  node.subscriptionManager.subscribe(plugin.config.metadataTopic).isOkOr:
    await node.stopMixRln()
    return err(error)
  return ok()
