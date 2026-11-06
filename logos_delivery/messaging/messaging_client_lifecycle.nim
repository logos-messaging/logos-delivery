## Messaging layer core: the `MessagingClient` type plus its construction and
## lifecycle. The public operations (subscribe / unsubscribe / send) live in
## `messaging/api.nim`.
import results, chronos
import chronicles
import
  logos_delivery/messaging/messaging_client,
  logos_delivery/messaging/api/send,
  logos_delivery/api/messaging_client_api,
  logos_delivery/waku/waku,
  logos_delivery/waku/api/subscriptions,
  logos_delivery/waku/persistency/persistency,
  logos_delivery/messaging/delivery_service/[recv_service, send_service]

# Surfaces the messaging API interface (and its Message* events) to consumers.
export messaging_client

const MessagingJobId* = "messaging"

proc getMessagingJob(brokerCtx: BrokerContext): persistency.Job =
  let persistency = GetPersistency.request(brokerCtx).valueOr:
    debug "Messaging persistence disabled, no persistency provider", reason = $error
    return nil
  let job = persistency.openJob(MessagingJobId).valueOr:
    warn "Messaging persistence disabled, could not open persistency job",
      jobId = MessagingJobId, reason = $error
    return nil
  return job

proc start*(self: MessagingClient): Result[void, string] =
  if self.started:
    return ok()
  if self.stopping:
    return err("MessagingClient is stopping")

  # Providers before services, so a failed setProvider leaves nothing running.
  # A failure clears only the providers this call set: the provider already in
  # place belongs to another owner.
  ?MessagingSend.setProvider(
    self.brokerCtx,
    proc(envelope: MessageEnvelope): Future[Result[RequestId, string]] {.async.} =
      return await self.send(envelope),
  )

  MessagingSubscribe.setProvider(
    self.brokerCtx,
    proc(contentTopic: ContentTopic): Result[void, string] =
      self.waku.subscribe(contentTopic),
  ).isOkOr:
    MessagingSend.clearProvider(self.brokerCtx)
    return err(error)

  MessagingUnsubscribe.setProvider(
    self.brokerCtx,
    proc(contentTopic: ContentTopic): Result[void, string] =
      self.waku.unsubscribe(contentTopic),
  ).isOkOr:
    MessagingSend.clearProvider(self.brokerCtx)
    MessagingSubscribe.clearProvider(self.brokerCtx)
    return err(error)

  self.persistencyJob = getMessagingJob(self.brokerCtx)
  self.recvService.startRecvService(self.persistencyJob)
  self.sendService.startSendService()

  self.started = true
  ok()

proc stop*(self: MessagingClient) {.async.} =
  if not self.started:
    return
  # The API calls fail from this point, also while the services below stop.
  self.started = false
  self.stopping = true
  defer:
    self.stopping = false
  MessagingSend.clearProvider(self.brokerCtx)
  MessagingSubscribe.clearProvider(self.brokerCtx)
  MessagingUnsubscribe.clearProvider(self.brokerCtx)
  await self.sendService.stopSendService()
  await self.recvService.stopRecvService()
  if not self.persistencyJob.isNil():
    let persistency = GetPersistency.request(self.brokerCtx)
    if persistency.isOk():
      persistency.get().closeJob(MessagingJobId)
    self.persistencyJob = nil
