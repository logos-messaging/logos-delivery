{.push raises: [].}
import chronos, chronicles, results
import mix_rln_spam_protection/module_api
import logos_delivery/api/events/kernel_events
import
  logos_delivery/waku/
    [waku_core, node/waku_node, node/subscription_manager, requests/rln_requests]
import ./[relay, lightpush]

proc publishMetadata(
    node: WakuNode, topic: string, data: seq[byte]
): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
  var message = WakuMessage(
    payload: data,
    contentTopic: topic,
    timestamp: getNowInNanosecondTime(),
    ephemeral: true,
  )
  # Coordination uses its separate Relay membership, outside send(Required).
  if not node.rlnLez.isNil() or not node.rln.isNil():
    let generated = (
      await RequestGenerateRlnProof.request(
        node.brokerCtx, message, uint64(message.timestamp div 1_000_000_000)
      )
    ).valueOr:
      return err(error)
    message.proof = generated.proof
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

proc stopMixRln*(node: WakuNode) {.async: (raises: []).} =
  if node.wakuMixRln.isNil():
    return
  if node.wakuMixRlnListener.isSome():
    await MessageSeenEvent.dropListener(node.brokerCtx, node.wakuMixRlnListener.get())
  node.wakuMixRlnListener = Opt.none(MessageSeenEventListener)
  await node.wakuMixRln.stop()

proc startMixRln*(
    node: WakuNode
): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
  if node.wakuMixRln.isNil():
    return ok()
  if node.rlnLez.isNil() and node.rln.isNil():
    return err("Mix RLN coordination requires Relay RLN")
  let plugin = node.wakuMixRln
  plugin.setPublishCallback(
    proc(topic: string, data: seq[byte]): Future[Result[void, string]] {.async.} =
      return await node.publishMetadata(topic, data)
  )
  (await plugin.start()).isOkOr:
    return err(error)
  if node.wakuMixRlnListener.isSome():
    return ok()
  let handler = proc(event: MessageSeenEvent): Future[void] {.async: (raises: []).} =
    if event.message.contentTopic == plugin.config.metadataTopic:
      plugin.handleProofMetadata(event.message.payload).isOkOr:
        debug "Rejected Mix coordination metadata", error
  let listener = MessageSeenEvent.listen(node.brokerCtx, handler).valueOr:
    await plugin.stop()
    return err(error)
  node.wakuMixRlnListener = Opt.some(listener)
  node.subscriptionManager.subscribe(plugin.config.metadataTopic).isOkOr:
    await node.stopMixRln()
    return err(error)
  return ok()
