## Messaging layer core: the `MessagingClient` type plus its construction and
## lifecycle. The public operations (subscribe / unsubscribe / send) live in
## `messaging/api.nim`.
import results, chronos
import chronicles
import
  logos_delivery/api/messaging_client_api,
  logos_delivery/api/requests/messaging_client_requests,
  logos_delivery/waku/waku,
  logos_delivery/messaging/delivery_service/[recv_service, send_service]

# Surfaces the messaging API interface (and its Message* events) to consumers.
export messaging_client_api

type
  MessagingClientConf* = object
    ## Per-layer config object for the messaging API.
    ## Kept intentionally minimal for now; the full config surface lands in a
    ## follow-up PR. Today it only carries the p2p reliability toggle.
    useP2PReliability*: bool

  MessagingClient* = ref object
    brokerCtx*: BrokerContext
    waku*: Waku ## The Waku kernel this layer drives; read by `messaging/api/*`.
    sendService*: SendService
    recvService*: RecvService
    started*: bool

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

proc checkApiAvailability*(self: MessagingClient): Result[void, string] =
  ## Shared guard for the api operation module.
  if self.isNil():
    return err("MessagingClient is not initialized")

  return ok()
