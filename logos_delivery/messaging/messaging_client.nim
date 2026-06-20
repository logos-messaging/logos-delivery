import results, chronos
import chronicles
import
  logos_delivery/waku/api/types,
  logos_delivery/waku/node/[waku_node, subscription_manager],
  logos_delivery/messaging/delivery_service/[recv_service, send_service],
  logos_delivery/messaging/delivery_service/send_service/delivery_task

type
  MessagingClientConf* = object
    ## Per-layer config object for the messaging API.
    ## Kept intentionally minimal for now; the full config surface lands in a
    ## follow-up PR. Today it only carries the p2p reliability toggle.
    useP2PReliability*: bool

  MessagingClient* = ref object
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

proc send*(
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
