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

func isSet*(flags: MessagingNodeConf): bool =
  ## True when the command line sets a Messaging API flag.
  for _, field in fieldPairs(flags):
    if field.isSome():
      return true
  return false
