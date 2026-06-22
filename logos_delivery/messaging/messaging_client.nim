import results, chronos
import chronicles
import brokers/broker_implement
import logos_delivery/api/messaging_client_interface
import
  logos_delivery/waku/api/types,
  logos_delivery/waku/node/[waku_node, subscription_manager],
  logos_delivery/messaging/delivery_service/[recv_service, send_service],
  logos_delivery/messaging/delivery_service/send_service/delivery_task

type MessagingClient* = ref object of MessagingClientInterface
  node: WakuNode
  sendService*: SendService
  recvService*: RecvService
  started: bool

proc start*(self: MessagingClient): Result[void, string] =
  if self.started:
    return ok()
  self.recvService.startRecvService()
  self.sendService.startSendService()
  self.started = true
  ok()

proc stop*(self: MessagingClient) {.async.} =
  if not self.started:
    return
  await self.sendService.stopSendService()
  await self.recvService.stopRecvService()
  self.started = false

BrokerImplement MessagingClient of MessagingClientInterface:
  proc new*(T: typedesc[MessagingClient], useP2PReliability: bool, node: WakuNode): T =
    let sendService = SendService.new(useP2PReliability, node).valueOr:
      error "Failed to initialize SendService", error = error
      quit(QuitFailure)

    let recvService = RecvService.new(node)
    T(node: node, sendService: sendService, recvService: recvService, started: false)

  method subscribe(
      self: MessagingClient, contentTopic: ContentTopic
  ): Future[Result[void, string]] {.async.} =
    return self.node.subscriptionManager.subscribe(contentTopic)

  method unsubscribe(
      self: MessagingClient, contentTopic: ContentTopic
  ): Future[Result[void, string]] {.async.} =
    return self.node.subscriptionManager.unsubscribe(contentTopic)

  method send(
      self: MessagingClient, envelope: MessageEnvelope
  ): Future[Result[RequestId, string]] {.async.} =
    ## High-level messaging API send. Auto-subscribes to the content topic
    ## (so the local node sees its own gossipsub broadcast), builds a
    ## `DeliveryTask`, and hands it to the send service. Returns the request
    ## id the caller can correlate with `MessageSentEvent` / `MessageErrorEvent`.
    let isSubbed =
      self.node.subscriptionManager.isSubscribed(envelope.contentTopic).valueOr(false)
    if not isSubbed:
      info "Auto-subscribing to topic on send", contentTopic = envelope.contentTopic
      self.node.subscriptionManager.subscribe(envelope.contentTopic).isOkOr:
        warn "Failed to auto-subscribe", error = error
        return err("Failed to auto-subscribe before sending: " & error)

    let requestId = RequestId.new(self.node.rng)

    let deliveryTask = DeliveryTask.new(requestId, envelope, self.node.brokerCtx).valueOr:
      return err("MessagingClient.send: Failed to create delivery task: " & error)

    asyncSpawn self.sendService.send(deliveryTask)

    return ok(requestId)
