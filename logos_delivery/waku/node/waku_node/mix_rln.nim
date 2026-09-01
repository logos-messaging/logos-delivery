{.push raises: [].}

import chronos, chronicles, results
import mix_rln_spam_protection/spam_protection as mix_rln

import
  logos_delivery/api/events/kernel_events,
  logos_delivery/waku/[waku_core, node/waku_node, node/subscription_manager]

import ./relay

logScope:
  topics = "waku mix rln"

proc publishMixRlnMessage(
    node: WakuNode, contentTopic: string, data: seq[byte]
): Future[Result[void, string]] {.async, gcsafe.} =
  let message = WakuMessage(
    payload: data,
    contentTopic: contentTopic,
    timestamp: getNowInNanosecondTime(),
    ephemeral: true,
  )

  (await node.publish(Opt.none(PubsubTopic), message)).isOkOr:
    return err(error)

  return ok()

proc handleMixRlnMessage(
    spamProtection: mix_rln.MixRlnSpamProtection, event: MessageSeenEvent
) {.async: (raises: []).} =
  try:
    let contentTopic = event.message.contentTopic
    if contentTopic == spamProtection.getMembershipContentTopic():
      (await spamProtection.handleMembershipUpdate(event.message.payload)).isOkOr:
        warn "Failed to handle Mix-RLN membership update", error
    elif contentTopic == spamProtection.getProofMetadataContentTopic():
      spamProtection.handleProofMetadata(event.message.payload).isOkOr:
        warn "Failed to handle Mix-RLN proof metadata", error
  except CatchableError as exc:
    warn "Exception handling Mix-RLN coordination message", error = exc.msg

proc mountMixRlnCoordination*(node: WakuNode): Result[void, string] =
  if node.wakuMixRln.isNil():
    return err("Mix-RLN is not configured")
  if node.wakuRelay.isNil():
    return err("Mix-RLN coordination requires Waku Relay")
  if node.wakuAutoSharding.isNone():
    return err("Mix-RLN coordination requires autosharding")
  if node.wakuMixRlnListener.isSome():
    return err("Mix-RLN coordination is already mounted")

  let spamProtection = node.wakuMixRln
  spamProtection.setPublishCallback(
    proc(
        contentTopic: string, data: seq[byte]
    ): Future[Result[void, string]] {.async, gcsafe.} =
      return await node.publishMixRlnMessage(contentTopic, data)
  )

  for contentTopic in spamProtection.getContentTopics():
    node.subscriptionManager.subscribe(contentTopic).isOkOr:
      return err("Failed to subscribe to Mix-RLN content topic: " & error)

  let handler = proc(event: MessageSeenEvent): Future[void] {.async: (raises: []).} =
    await spamProtection.handleMixRlnMessage(event)

  let listener = MessageSeenEvent.listen(node.brokerCtx, handler).valueOr:
    return err("Failed to register Mix-RLN message listener: " & error)
  node.wakuMixRlnListener = Opt.some(listener)

  return ok()

{.pop.}
