## Messaging layer core: the `MessagingClient` type plus its construction and
## lifecycle. The public operations (subscribe / unsubscribe / send) live in
## `messaging/api.nim`.
import results, chronos
import chronicles
import brokers/[request_broker, broker_context]
import
  logos_delivery/api/messaging_client_api,
  logos_delivery/waku/waku,
  logos_delivery/messaging/delivery_service/[recv_service, send_service]

# Surfaces the messaging API interface (and its Message* events) to consumers.
export messaging_client_api

RequestBroker:
  proc MessagingSend(
    envelope: MessageEnvelope
  ): Future[Result[RequestId, string]] {.async.}

type
  MessagingClientConf* = object
    ## Per-layer config object for the messaging API.
    ## Kept intentionally minimal for now; the full config surface lands in a
    ## follow-up PR. Today it only carries the p2p reliability toggle.
    useP2PReliability*: bool

  MessagingClient* = ref object of IMessagingClient
    brokerCtx: BrokerContext
    waku*: Waku ## The Waku kernel this layer drives; read by `messaging/api/*`.
    sendService*: SendService
    recvService*: RecvService
    started: bool

proc new*(
    T: type MessagingClient, conf: MessagingClientConf, waku: Waku
): Result[T, string] =
  ## The messaging layer chains onto Waku: it drives the underlying Waku kernel
  ## for transport while exposing its own send/recv API.
  let sendService = ?SendService.new(conf.useP2PReliability, waku)
  let recvService = RecvService.new(waku)
  return ok(
    T(
      waku: waku,
      sendService: sendService,
      recvService: recvService,
      brokerCtx: waku.brokerCtx,
    )
  )

proc start*(self: MessagingClient): Result[void, string] =
  if self.started:
    return ok()
  self.recvService.startRecvService()
  self.sendService.startSendService()

  ?MessagingSend.setProvider(
    self.brokerCtx,
    proc(envelope: MessageEnvelope): Future[Result[RequestId, string]] {.async.} =
      return await self.send(envelope),
  )

  self.started = true
  ok()

proc stop*(self: MessagingClient) {.async.} =
  if not self.started:
    return
  MessagingSend.clearProvider(self.brokerCtx)
  await self.sendService.stopSendService()
  await self.recvService.stopRecvService()
  self.started = false

proc checkApiAvailability*(self: MessagingClient): Result[void, string] =
  ## Shared guard for the api operation module.
  if self.isNil():
    return err("MessagingClient is not initialized")

  return ok()
