## Messaging layer core: the `MessagingClient` type plus its construction and
## lifecycle. The public operations (subscribe / unsubscribe / send) live in
## `messaging/api.nim`.
import results, chronos, chronicles
import
  logos_delivery/api/conf/messaging_conf,
  logos_delivery/api/messaging_client_api,
  logos_delivery/waku/waku,
  logos_delivery/waku/factory/conf_builder/waku_conf_builder,
  logos_delivery/messaging/delivery_service/[recv_service, send_service]

export messaging_client_api, messaging_conf

type MessagingClient* = ref object
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
  let reliability = conf.reliabilityEnabled.get(DefaultP2pReliability)
  let sendService = ?SendService.new(reliability, waku)
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
