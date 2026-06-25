import results, chronos
import chronicles
import
  logos_delivery/api/types,
  logos_delivery/api/messaging_client_api,
  logos_delivery/waku/node/[waku_node, subscription_manager],
  logos_delivery/messaging/delivery_service/[recv_service, send_service],
  logos_delivery/messaging/delivery_service/send_service/delivery_task

type
  MessagingClientConf* = object
    ## Per-layer config object for the messaging API.
    ## Kept intentionally minimal for now; the full config surface lands in a
    ## follow-up PR. Today it only carries the p2p reliability toggle.
    useP2PReliability*: bool

  MessagingClient* = ref object of IMessagingClient
    node: WakuNode
    sendService*: SendService
    recvService*: RecvService
    started: bool

proc new*(
    T: type MessagingClient, conf: MessagingClientConf, node: WakuNode
): Result[T, string] =
  ## The messaging layer chains onto Waku: it drives the underlying
  ## `WakuNode` (Waku's core) for transport while exposing its own send/recv API.
  let sendService = ?SendService.new(conf.useP2PReliability, node)
  let recvService = RecvService.new(node)
  ok(T(node: node, sendService: sendService, recvService: recvService))

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

proc checkApiAvailability(self: MessagingClient): Result[void, string] =
  if self.isNil():
    return err("MessagingClient is not initialized")
  return ok()

method subscribe*(
    self: MessagingClient, contentTopic: ContentTopic
): Future[Result[void, string]] {.async: (raises: []).} =
  ?checkApiAvailability(self)

  return self.node.subscriptionManager.subscribe(contentTopic)

method unsubscribe*(
    self: MessagingClient, contentTopic: ContentTopic
): Result[void, string] {.raises: [].} =
  ?checkApiAvailability(self)

  return self.node.subscriptionManager.unsubscribe(contentTopic)

method send*(
    self: MessagingClient, envelope: MessageEnvelope
): Future[Result[RequestId, string]] {.async: (raises: []).} =
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
