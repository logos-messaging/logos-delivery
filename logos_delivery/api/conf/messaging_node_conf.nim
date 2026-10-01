## Leaf module for the Messaging API flags of the node command line.
##
## `cli_args` flattens `MessagingNodeConf` into `LogosDeliveryNodeConf`, so this
## module imports nothing from the config/api layers. `messaging_conf` turns the
## flags into a `MessagingClientConf`.

import results, confutils/defs
import logos_delivery/api/conf/modes

export modes

type MessagingNodeConf* = object
  ## The Messaging API flags of the node command line. The flags are Opt-typed,
  ## so that a set flag overrides the network preset. The desc states the default.
  reliabilityEnabled* {.
    desc:
      "Confirm each send against a Store node: true|false. Default is the value of the network preset, or true without a preset.",
    defaultValue: Opt.none(bool),
    name: "reliability"
  .}: Opt[bool]

  anonymityLevel* {.
    desc:
      "Sender anonymity level: None, Preferred or Required. A level above None mounts mix. Default is None.",
    defaultValue: Opt.none(AnonymityLevel),
    name: "anonymity-level"
  .}: Opt[AnonymityLevel]

  rateLimitEnabled* {.
    desc:
      "Enforce the per-epoch send rate limit of the Messaging API: true|false. Default is false.",
    defaultValue: Opt.none(bool),
    name: "rate-limit-enabled"
  .}: Opt[bool]

  rateLimitEpochPeriodSec* {.
    desc: "Send rate-limit epoch length, in seconds. Default is 600.",
    defaultValue: Opt.none(uint64),
    name: "rate-limit-epoch-sec"
  .}: Opt[uint64]

  rateLimitMessagesPerEpoch* {.
    desc: "Messages admitted per send rate-limit epoch. Default is 1.",
    defaultValue: Opt.none(uint64),
    name: "rate-limit-messages-per-epoch"
  .}: Opt[uint64]

  rateLimitApproachedThresholdPercent* {.
    desc:
      "Share of the send rate-limit budget, in percent, at which the quota counts as approached. Default is 80.",
    defaultValue: Opt.none(uint64),
    name: "rate-limit-approached-threshold-percent"
  .}: Opt[uint64]

  maxParkedAgeSec* {.
    desc:
      "Max age in seconds, from the message timestamp, of a send that waits for rate-limit budget. Default is 1800.",
    defaultValue: Opt.none(uint),
    name: "max-parked-age-sec"
  .}: Opt[uint]

  sendQueueCapacity* {.
    desc:
      "Max messages that the send service tracks. Sends beyond it are rejected. Default is 1000.",
    defaultValue: Opt.none(uint),
    name: "send-queue-capacity"
  .}: Opt[uint]

  backfillEnabled* {.
    desc:
      "Get from Store the messages sent while the node was stopped: true|false. Default is true.",
    defaultValue: Opt.none(bool),
    name: "backfill-enabled"
  .}: Opt[bool]

  backfillRequestTimeoutSeconds* {.
    desc: "Timeout of one backfill Store query, in seconds (1 .. 300). Default is 10.",
    defaultValue: Opt.none(int64),
    name: "backfill-request-timeout-seconds"
  .}: Opt[int64]

func isSet*(flags: MessagingNodeConf): bool =
  ## True when the command line sets a Messaging API flag.
  for _, field in fieldPairs(flags):
    if field.isSome():
      return true
  return false
