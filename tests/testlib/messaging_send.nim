import chronos, results
import logos_delivery/api/types, logos_delivery/messaging/[messaging_client, api/send]
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
