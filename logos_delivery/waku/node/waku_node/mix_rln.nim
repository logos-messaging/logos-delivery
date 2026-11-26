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
import ./relay

type
  MixMembershipReadFailure* {.pure.} = enum
    NoAnswer ## The RLN module did not answer.
    UnknownState ## It answered with a state this node does not know.

  MixMembershipReadError* = object
    failure*: MixMembershipReadFailure
    state*: string ## The state it answered, for `UnknownState`.
    msg*: string

proc readMixMembership*(
    plugin: ModuleRlnProtection
): Future[Result[MembershipStatus, MixMembershipReadError]] {.
    async: (raises: [CancelledError])
.} =
  ## The state of this node's membership in the Mix registry, read from the RLN
  ## module on the Mix scope. The library does not acquire the membership: the
  ## host's RLN module adopts, pays for or is granted one.
  let reply = (await plugin.scopedCall("get_membership_state")).valueOr:
    return err(
      MixMembershipReadError(failure: MixMembershipReadFailure.NoAnswer, msg: error)
    )
  let state = reply{"state"}.getStr("")
  let status = parseRlnMembershipStatus(state).valueOr:
    return err(
      MixMembershipReadError(
        failure: MixMembershipReadFailure.UnknownState, state: state, msg: $error
      )
    )
  return ok(status)

proc noteUnknownMixMembershipState(node: WakuNode, read: MixMembershipReadError) =
  ## Warns once for each unknown state in a row. The node keeps its last known
  ## answer: an unknown state points at a mismatch with the RLN module, and
  ## dropping the mix key would hold the next advert back at the registrars.
  if node.mixMembershipUnknownState == Opt.some(read.state):
    return
  node.mixMembershipUnknownState = Opt.some(read.state)
  warn "The RLN module answered a Mix membership state this node does not know; " &
    "keeping the last known answer",
    state = read.state, usable = node.mixMembershipUsable

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
  # Only a node that relays publishes coordination: `startMixRln` gives a node
  # without Relay a publisher that drops it.
  try:
    let peers = (await node.publish(Opt.none(PubsubTopic), message)).valueOr:
      return err("Mix coordination publish failed: " & error)
    if peers == 0:
      return err("No Relay peers for Mix coordination")
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
    case error.failure
    of MixMembershipReadFailure.NoAnswer:
      debug "Mix membership check got no answer", error = error.msg
    of MixMembershipReadFailure.UnknownState:
      node.noteUnknownMixMembershipState(error)
    return
  node.mixMembershipUnknownState = Opt.none(string)
  let usable = status.isUsable()
  if usable == node.mixMembershipUsable:
    return
  node.mixMembershipUsable = usable
  if usable:
    info "Mix RLN membership is usable", status = $status
  else:
    notice "Mix RLN membership is no longer usable; this node cannot prove a Mix hop",
      status = $status
  MixMembershipChangedEvent.emit(
    node.brokerCtx, MixMembershipChangedEvent(usable: usable)
  )
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
  ## A node that relays (Core) also coordinates: it publishes
  ## the metadata of the proofs it verifies over Relay, with a Relay RLN proof,
  ## and applies what other nodes publish. A node without Relay (Edge) is no
  ## hop for others and takes no part in coordination: it needs no Relay RLN
  ## here, publishes nothing and does not subscribe to the metadata topic. It
  ## still checks the proofs it verifies against its own nullifier log.
  if node.wakuMixRln.isNil():
    return err("Mix RLN is not configured")
  let coordinates = not node.wakuRelay.isNil()
  if coordinates and node.rlnPlugin.isNone():
    return err("Mix RLN coordination requires Relay RLN")
  let plugin = node.wakuMixRln
  if coordinates:
    plugin.setPublishCallback(
      proc(topic: string, data: seq[byte]): Future[Result[void, string]] {.async.} =
        return await node.publishMetadata(topic, data)
    )
  else:
    # The plugin refuses to start without a publisher.
    plugin.setPublishCallback(
      proc(topic: string, data: seq[byte]): Future[Result[void, string]] {.async.} =
        return ok()
    )
    info "Mix RLN without coordination: this node does not relay"
  (await plugin.start()).isOkOr:
    return err("Failed to start Mix RLN plugin: " & $error)
  # A node without a usable Mix membership cannot prove a hop. That does not
  # stop startup: the membership can arrive later.
  let membership = await plugin.readMixMembership()
  node.mixMembershipUsable = membership.isOk() and membership.get().isUsable()
  node.mixMembershipUnknownState = Opt.none(string)
  if membership.isErr():
    case membership.error.failure
    of MixMembershipReadFailure.NoAnswer:
      warn "RLN backend did not answer the Mix membership check",
        error = membership.error.msg
    of MixMembershipReadFailure.UnknownState:
      node.noteUnknownMixMembershipState(membership.error)
  elif not node.mixMembershipUsable:
    notice "No usable Mix RLN membership; this node cannot prove a Mix hop until it is active",
      status = $membership.get()
  else:
    info "Mix RLN membership verified", status = $membership.get()
  if node.mixMembershipLoop.isNil():
    node.mixMembershipLoop = node.watchMixMembership()
  if not coordinates or node.wakuMixRlnListener.isSome():
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
