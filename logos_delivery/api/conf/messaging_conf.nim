import results

import logos_delivery/api/conf/kernel_conf
import logos_delivery/waku/factory/networks_config
import logos_delivery/messaging/rate_limit_manager/rate_limit_config

export kernel_conf, rate_limit_config

# `LogosDeliveryMode` and `EntryLayer` are defined in the leaf module `modes`, so
# that they can appear on `LogosDeliveryNodeConf` in `cli_args`. `kernel_conf`
# re-exports them here.

type MessagingClientConf* = object
  ## Messaging-only options. The kernel options of a messaging node live in its
  ## kernel config.
  reliabilityEnabled* {.name: "reliability".}: Opt[bool]
    ## Enable store-based send reliability.
  anonymityLevel* {.name: "anonymity-level".}: Opt[AnonymityLevel]
    ## Sender anonymity level. A level above `None` mounts and uses mix.
  rateLimitEnabled* {.name: "rate-limit-enabled".}: Opt[bool]
    ## Enforce the per-epoch send rate limit (default false).
  rateLimitEpochPeriodSec* {.name: "rate-limit-epoch-sec".}: Opt[uint64]
    ## Rate-limit epoch length, in seconds.
  rateLimitMessagesPerEpoch* {.name: "rate-limit-messages-per-epoch".}: Opt[uint64]
    ## Messages admitted per rate-limit epoch.
  rateLimitApproachedThresholdPercent* {.
    name: "rate-limit-approached-threshold-percent"
  .}: Opt[uint64]
    ## Share of the epoch budget, in percent, at which the quota counts as
    ## approached (default 80).
  maxParkedAgeSec* {.name: "max-parked-age-sec".}: Opt[uint]
    ## Max age, from the message timestamp, of a send still waiting for
    ## rate-limit budget before it fails with `MessageErrorEvent` (default 1800).
  sendQueueCapacity* {.name: "send-queue-capacity".}: Opt[uint]
    ## Max messages tracked by the send service; sends beyond it are rejected
    ## (default 1000).
  backfillEnabled* {.name: "backfill-enabled".}: Opt[bool]
    ## Store catch-up of missed messages after a start (default true). A
    ## start with false deletes the saved catch-up state.
  backfillRequestTimeoutSeconds* {.name: "backfill-request-timeout-seconds".}:
    Opt[int64] ## Timeout of one Store query, in seconds (default 10, 1 .. 300).

proc rateLimitConfig*(self: MessagingClientConf): RateLimitConfig =
  ## Unset fields fall back to `DefaultRateLimitConfig`.
  return RateLimitConfig(
    enabled: self.rateLimitEnabled.get(DefaultRateLimitConfig.enabled),
    epochPeriodSec:
      self.rateLimitEpochPeriodSec.get(DefaultRateLimitConfig.epochPeriodSec),
    messagesPerEpoch:
      self.rateLimitMessagesPerEpoch.get(DefaultRateLimitConfig.messagesPerEpoch),
    approachedThresholdPercent: self.rateLimitApproachedThresholdPercent.get(
      DefaultRateLimitConfig.approachedThresholdPercent
    ),
  )

proc merge*(base, overrides: MessagingClientConf): MessagingClientConf =
  var m = base
  for _, mField, oField in fieldPairs(m, overrides):
    when oField is Opt:
      if oField.isSome():
        mField = oField

  return m

proc resolvePreset*(preset: string): ConfResult[MessagingClientConf] =
  ## Preset to messaging fields. The kernel resolves its own fields from
  ## `conf.preset`.
  let npcOpt = ?toNetworkPresetConf(preset, Opt.none(uint16))
  if npcOpt.isNone():
    return ok(MessagingClientConf())
  let npc = npcOpt.get()
  return ok(MessagingClientConf(reliabilityEnabled: Opt.some(npc.p2pReliability)))

proc init*(
    T: type MessagingClientConf, flags: MessagingNodeConf, preset: string
): ConfResult[MessagingClientConf] =
  ## The messaging config of a node that starts from the command line. A set flag
  ## overrides the value of the network preset.
  let fromFlags = MessagingClientConf(
    reliabilityEnabled: flags.reliabilityEnabled, anonymityLevel: flags.anonymityLevel
  )
  return ok(merge(?resolvePreset(preset), fromFlags))
