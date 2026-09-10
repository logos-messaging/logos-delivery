## Messaging layer core: the `MessagingClient` type plus its construction and
## lifecycle. The public operations (subscribe / unsubscribe / send) live in
## `messaging/api.nim`.
import std/sequtils, results, chronos, chronicles
import
  logos_delivery/api/conf/messaging_conf,
  logos_delivery/api/messaging_client_api,
  logos_delivery/waku/waku,
  logos_delivery/waku/api/[publish, health],
  logos_delivery/waku/node/health_monitor,
  logos_delivery/waku/factory/conf_builder/waku_conf_builder,
  logos_delivery/waku/persistency/persistency,
  logos_delivery/messaging/delivery_service/[recv_service, send_service],
  logos_delivery/messaging/rate_limit_manager/rate_limit_manager

export messaging_client_api, messaging_conf

type MessagingClient* = ref object
  brokerCtx*: BrokerContext
  waku*: Waku ## The Waku kernel this layer drives; read by `messaging/api/*`.
  sendService*: SendService
  recvService*: RecvService
  persistencyJob*: persistency.Job
  started*: bool

proc rlnQuotaProvider(waku: Waku): QuotaProvider =
  ## Sources the rate limit manager's epoch and limit from RLN. The closure
  ## queries `waku` on each admission, so a node whose RLN mounts after
  ## construction upgrades from the wall-clock fallback automatically.
  return proc(): Opt[EpochQuota] {.gcsafe, raises: [].} =
    let q = waku.currentRlnEpochQuota().valueOr:
      return Opt.none(EpochQuota)
    return
      Opt.some(EpochQuota(epochIndex: q.epochIndex, userMessageLimit: q.messageLimit))

proc requireMixReady*(
    status: ConnectionStatus, protocols: seq[ProtocolHealth]
): ConnectionStatus {.gcsafe, raises: [].} =
  ## `Required` has no plain fallback, so without mix nothing can be sent.
  if protocols.anyIt(it.protocol == $MixProtocol and it.health == HealthStatus.READY):
    return status
  return ConnectionStatus.Disconnected

proc new*(
    T: type MessagingClient, conf: MessagingClientConf, waku: Waku
): Result[T, string] =
  ## The messaging layer chains onto Waku: it drives the underlying Waku kernel
  ## for transport while exposing its own send/recv API.
  let reliability = conf.reliabilityEnabled.get(DefaultP2pReliability)
  let anonymityLevel = conf.anonymityLevel.get(AnonymityLevel.None)
  let rateLimitManager = ?RateLimitManager.new(
    conf.rateLimit.get(DefaultRateLimitConfig), rlnQuotaProvider(waku)
  )
  let sendService = ?SendService.new(
    reliability, waku, rateLimitManager, anonymityLevel = anonymityLevel
  )
  let backfill = ?BackfillState.init(conf)
  let recvService = RecvService.new(waku, backfill)

  if anonymityLevel == AnonymityLevel.Required:
    waku.setConnectionStatusAdjuster(requireMixReady)

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
