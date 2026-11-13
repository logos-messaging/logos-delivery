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
  logos_delivery/messaging/delivery_service/send_service/transports,
  logos_delivery/messaging/rate_limit_manager/rate_limit_manager

export messaging_client_api, messaging_conf

type MessagingClient* = ref object
  brokerCtx*: BrokerContext
  waku*: Waku ## The Waku kernel this layer drives; read by `messaging/api/*`.
  sendService*: SendService
  rateLimitManager*: RateLimitManager
  recvService*: RecvService
  persistencyJob*: persistency.Job
  started*: bool
    ## `start` sets it last and `stop` clears it first. `checkApiAvailability` reads it.
  stopping*: bool ## True while `stop` runs.

proc rlnQuotaProvider(waku: Waku): QuotaProvider =
  ## Sources the rate limit manager's epoch budget from RLN. The closure
  ## queries `waku` on each call, so a node whose RLN mounts after
  ## construction upgrades from the local fallback automatically.
  return proc(
      timestamp: uint64
  ): Future[Opt[EpochQuota]] {.async: (raises: []), gcsafe.} =
    let res =
      try:
        await waku.rlnEpochQuota(timestamp)
      except CatchableError:
        return Opt.none(EpochQuota)
    let quota = res.valueOr:
      return Opt.none(EpochQuota)
    return Opt.some(quota)

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
  let rateLimitConfig = conf.rateLimitConfig()
  let rateLimitManager = ?RateLimitManager.new(
    rateLimitConfig,
    rlnQuotaProvider(waku),
    epochSizeProvider = proc(): Opt[uint64] {.gcsafe, raises: [].} =
      waku.rlnEpochSizeSec(),
  )
  let sendService = ?SendService.new(
    reliability, waku, rateLimitManager, Transports.init(waku), anonymityLevel
  )
  let backfill = ?BackfillState.init(conf)
  let recvService = RecvService.new(waku, backfill)

  if anonymityLevel == AnonymityLevel.Required:
    waku.setConnectionStatusAdjuster(requireMixReady)
  # Log the values that the preset, the flags and the defaults give.
  info "Messaging API settings",
    reliability = reliability,
    anonymityLevel = anonymityLevel,
    rateLimitEnabled = rateLimitConfig.enabled,
    rateLimitEpochPeriodSec = rateLimitConfig.epochPeriodSec,
    rateLimitMessagesPerEpoch = rateLimitConfig.messagesPerEpoch,
    backfillEnabled = backfill.enabled,
    backfillRequestTimeout = backfill.queryTimeout

  return ok(
    T(
      waku: waku,
      sendService: sendService,
      rateLimitManager: rateLimitManager,
      recvService: recvService,
      brokerCtx: waku.brokerCtx,
    )
  )

proc checkApiAvailability*(self: MessagingClient): Result[void, string] =
  ## Shared guard for the api operation module.
  if self.isNil():
    return err("MessagingClient is not initialized")
  if not self.started:
    return err("node is not started")

  return ok()
