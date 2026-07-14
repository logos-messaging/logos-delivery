import chronicles, results
import ../waku_conf

logScope:
  topics = "waku conf builder filter service"

const
  DefaultFilterEnabled: bool = false
  DefaultFilterMaxPeersToServe: uint32 = 500
  DefaultFilterSubscriptionTimeout: uint16 = 300
  DefaultFilterMaxCriteria: uint32 = 1000

###################################
## Filter Service Config Builder ##
###################################
type FilterServiceConfBuilder* = object
  enabled*: Opt[bool]
  maxPeersToServe*: Opt[uint32]
  subscriptionTimeout*: Opt[uint16]
  maxCriteria*: Opt[uint32]

proc init*(T: type FilterServiceConfBuilder): FilterServiceConfBuilder =
  FilterServiceConfBuilder()

proc withEnabled*(b: var FilterServiceConfBuilder, enabled: bool) =
  b.enabled = Opt.some(enabled)

proc withMaxPeersToServe*(b: var FilterServiceConfBuilder, maxPeersToServe: uint32) =
  b.maxPeersToServe = Opt.some(maxPeersToServe)

proc withMaxPeersToServeIfNotAssigned*(
    b: var FilterServiceConfBuilder, maxPeersToServe: uint32
) =
  if b.maxPeersToServe.isNone():
    b.maxPeersToServe = Opt.some(maxPeersToServe)

proc withSubscriptionTimeout*(
    b: var FilterServiceConfBuilder, subscriptionTimeout: uint16
) =
  b.subscriptionTimeout = Opt.some(subscriptionTimeout)

proc withMaxCriteria*(b: var FilterServiceConfBuilder, maxCriteria: uint32) =
  b.maxCriteria = Opt.some(maxCriteria)

proc build*(b: FilterServiceConfBuilder): Result[Opt[FilterServiceConf], string] =
  if not b.enabled.get(DefaultFilterEnabled):
    return ok(Opt.none(FilterServiceConf))

  return ok(
    Opt.some(
      FilterServiceConf(
        maxPeersToServe: b.maxPeersToServe.get(DefaultFilterMaxPeersToServe),
        subscriptionTimeout: b.subscriptionTimeout.get(DefaultFilterSubscriptionTimeout),
        maxCriteria: b.maxCriteria.get(DefaultFilterMaxCriteria),
      )
    )
  )
