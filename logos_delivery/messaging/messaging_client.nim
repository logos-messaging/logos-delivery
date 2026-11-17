## Messaging layer core: the `MessagingClient` type plus its construction and
## lifecycle. The public operations (subscribe / unsubscribe / send /
## queryHistory) live in `messaging/api/`.
import std/[sequtils, times], results, chronos, chronicles
import
  logos_delivery/api/conf/messaging_conf,
  logos_delivery/api/messaging_client_api,
  logos_delivery/waku/waku,
  logos_delivery/waku/api/[publish, health, store],
  logos_delivery/waku/node/health_monitor,
  logos_delivery/waku/factory/conf_builder/waku_conf_builder,
  logos_delivery/waku/persistency/persistency,
  logos_delivery/waku/waku_store/common,
  logos_delivery/messaging/delivery_service/
    [recv_service, send_service, history_query_service],
  logos_delivery/messaging/rate_limit_manager/rate_limit_manager

export messaging_client_api, messaging_conf

type MessagingClient* = ref object
  brokerCtx*: BrokerContext
  waku*: Waku ## The Waku kernel this layer drives; read by `messaging/api/*`.
  sendService*: SendService
  recvService*: RecvService
  historyQueryService*: HistoryQueryService
  persistencyJob*: persistency.Job
  started*: bool
    ## `start` sets it last and `stop` clears it first. `checkApiAvailability` reads it.
  stopping*: bool ## True while `stop` runs.

const
  MaxParkedAgeSecLimit = 7'u * 24 * 3600
  SendQueueCapacityLimit = 1_000_000'u

proc rlnQuotaProvider(waku: Waku): QuotaProvider =
  ## Sources the rate limit manager's epoch budget from RLN. The closure
  ## queries `waku` on each admission, so a node whose RLN mounts after
  ## construction upgrades from the local fallback automatically.
  return proc(): Future[Opt[EpochQuota]] {.async: (raises: []), gcsafe.} =
    let res =
      try:
        await waku.rlnEpochQuota(uint64(getTime().toUnix()))
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
  let rateLimitManager = ?RateLimitManager.new(rateLimitConfig, rlnQuotaProvider(waku))
  let maxParkedAgeSec = conf.maxParkedAgeSec.get(uint(DefaultMaxParkedAge.seconds()))
  if maxParkedAgeSec notin 1'u .. MaxParkedAgeSecLimit:
    return err("maxParkedAgeSec must be between 1 and " & $MaxParkedAgeSecLimit)
  let sendQueueCapacity = conf.sendQueueCapacity.get(uint(DefaultSendQueueCapacity))
  if sendQueueCapacity notin 1'u .. SendQueueCapacityLimit:
    return err("sendQueueCapacity must be between 1 and " & $SendQueueCapacityLimit)
  let sendProcessor = setupSendProcessorChain(waku, anonymityLevel).valueOr:
    return err("failed to setup SendProcessorChain: " & error)
  let sendService = ?SendService.new(
    reliability,
    waku,
    rateLimitManager,
    sendProcessor,
    anonymityLevel = anonymityLevel,
    maxParkedAge = seconds(int64(maxParkedAgeSec)),
    sendQueueCapacity = int(sendQueueCapacity),
  )
  let backfill = ?BackfillState.init(conf)
  let recvService = RecvService.new(waku, backfill)
  let historyQueryService = HistoryQueryService.new(
    waku.brokerCtx,
    proc(
        request: StoreQueryRequest
    ): Future[Result[StoreQueryResponse, string]] {.async.} =
      return await waku.storeQueryToAny(request),
    backfill.queryTimeout,
  )

  if anonymityLevel == AnonymityLevel.Required:
    waku.setConnectionStatusAdjuster(requireMixReady)
  # Log the values that the preset, the flags and the defaults give.
  info "Messaging API settings",
    reliability = reliability,
    anonymityLevel = anonymityLevel,
    rateLimitEnabled = rateLimitConfig.enabled,
    rateLimitEpochPeriodSec = rateLimitConfig.epochPeriodSec,
    rateLimitMessagesPerEpoch = rateLimitConfig.messagesPerEpoch,
    maxParkedAgeSec = maxParkedAgeSec,
    sendQueueCapacity = sendQueueCapacity,
    backfillEnabled = backfill.enabled,
    backfillRequestTimeout = backfill.queryTimeout

  return ok(
    T(
      waku: waku,
      sendService: sendService,
      recvService: recvService,
      historyQueryService: historyQueryService,
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
