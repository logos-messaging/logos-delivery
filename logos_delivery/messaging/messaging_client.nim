## Messaging layer core: the `MessagingClient` type plus its construction and
## lifecycle. The public operations (subscribe / unsubscribe / send) live in
## `messaging/api.nim`.
import results, chronos
import
  logos_delivery/api/messaging_client_api,
  logos_delivery/waku/node/waku_node,
  logos_delivery/messaging/delivery_service/[recv_service, send_service]

# Surfaces the messaging API interface (and its Message* events) to consumers.
export messaging_client_api

type
  MessagingClientConf* = object
    ## Per-layer config object for the messaging API.
    ## Kept intentionally minimal for now; the full config surface lands in a
    ## follow-up PR. Today it only carries the p2p reliability toggle.
    useP2PReliability*: bool

  MessagingClient* = ref object of IMessagingClient
    node*: WakuNode ## Waku core driven by this layer; read by `messaging/api.nim`.
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

proc checkApiAvailability*(self: MessagingClient): Result[void, string] =
  ## Shared guard for the api operation module.
  if self.isNil():
    return err("MessagingClient is not initialized")

  return ok()
