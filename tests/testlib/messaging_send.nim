import chronos, results, stew/byteutils
import
  logos_delivery/api/types,
  logos_delivery/messaging/[messaging_client, api/send],
  logos_delivery/waku/waku_core
import ./futures

proc sendWhenRoom*(
    client: MessagingClient, envelope: MessageEnvelope, timeout = FUTURE_TIMEOUT_LONG
): Future[SendResult] {.async.} =
  ## Sends `envelope` again while the node refuses it with `QueueFull`.
  ## An app does the same when it sends more than `MaxSendsInFlight` messages at once.
  let deadline = Moment.now() + timeout
  while true:
    let res = await client.send(envelope)
    if res.isOk() or res.error.kind != SendErrorKind.QueueFull or Moment.now() > deadline:
      return res
    await sleepAsync(chronos.milliseconds(5))

proc fakeHash*(id: string): WakuMessageHash =
  ## The message hash that a fake `MessagingSend` provider returns.
  ## Each id gives its own hash.
  return computeMessageHash(DefaultPubsubTopic, WakuMessage(payload: id.toBytes()))
