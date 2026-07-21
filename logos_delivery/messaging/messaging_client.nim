## Messaging layer core: the `MessagingClient` type plus its construction and
## lifecycle. The public operations (subscribe / unsubscribe / send) live in
## `messaging/api.nim`.
import results, chronos, chronicles
import
  logos_delivery/api/conf/messaging_conf,
  logos_delivery/api/messaging_client_api,
  logos_delivery/waku/waku,
  logos_delivery/waku/api/publish,
  logos_delivery/waku/factory/conf_builder/waku_conf_builder,
  logos_delivery/messaging/delivery_service/[recv_service, send_service],
  logos_delivery/messaging/rate_limit_manager/rate_limit_manager

export messaging_client_api, messaging_conf

type MessagingClient* = ref object
  brokerCtx*: BrokerContext
  waku*: Waku ## The Waku kernel this layer drives; read by `messaging/api/*`.
  sendService*: SendService
  recvService*: RecvService
  started*: bool

proc rlnQuotaProvider(waku: Waku): QuotaProvider =
  ## Sources the rate limit manager's epoch + limit from RLN. Late-binding: the
  ## closure queries `waku` on each admission, so a node whose RLN mounts after
  ## this client is constructed upgrades from the wall-clock fallback to RLN's
  ## epoch and user message limit automatically.
  return proc(): Opt[EpochQuota] {.gcsafe, raises: [].} =
    let q = waku.currentRlnEpochQuota().valueOr:
      return Opt.none(EpochQuota)
    Opt.some(EpochQuota(epochIndex: q.epochIndex, userMessageLimit: q.messageLimit))

proc new*(
    T: type MessagingClient, conf: MessagingClientConf, waku: Waku
): Result[T, string] =
  ## The messaging layer chains onto Waku: it drives the underlying Waku kernel
  ## for transport while exposing its own send/recv API.
  let reliability = conf.reliabilityEnabled.get(DefaultP2pReliability)
  let sendService = ?SendService.new(
    reliability,
    waku,
    RateLimitManager.new(
      conf.rateLimit.get(DefaultRateLimitConfig), rlnQuotaProvider(waku)
    ),
  )
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
