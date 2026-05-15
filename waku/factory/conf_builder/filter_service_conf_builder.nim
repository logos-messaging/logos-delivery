import chronicles, std/options, results
import ../waku_conf

logScope:
  topics = "waku conf builder filter service"

const
  DefaultFilterEnabled*: bool = false
  DefaultFilterMaxPeersToServe*: uint32 = 500
  DefaultFilterSubscriptionTimeout*: uint16 = 300
  DefaultFilterMaxCriteria*: uint32 = 1000

###################################
## Filter Service Config Builder ##
###################################
type FilterServiceConfBuilder* = object
  enabled*: Option[bool]
  maxPeersToServe*: Option[uint32]
  subscriptionTimeout*: Option[uint16]
  maxCriteria*: Option[uint32]

proc init*(T: type FilterServiceConfBuilder): FilterServiceConfBuilder =
  FilterServiceConfBuilder()

proc withEnabled*(b: var FilterServiceConfBuilder, enabled: bool) =
  b.enabled = some(enabled)

proc withMaxPeersToServe*(b: var FilterServiceConfBuilder, maxPeersToServe: uint32) =
  b.maxPeersToServe = some(maxPeersToServe)

proc withMaxPeersToServeIfNotAssigned*(
    b: var FilterServiceConfBuilder, maxPeersToServe: uint32
) =
  if b.maxPeersToServe.isNone():
    b.maxPeersToServe = some(maxPeersToServe)

proc withSubscriptionTimeout*(
    b: var FilterServiceConfBuilder, subscriptionTimeout: uint16
) =
  b.subscriptionTimeout = some(subscriptionTimeout)

proc withMaxCriteria*(b: var FilterServiceConfBuilder, maxCriteria: uint32) =
  b.maxCriteria = some(maxCriteria)

proc build*(b: FilterServiceConfBuilder): Result[Option[FilterServiceConf], string] =
  if not b.enabled.get(DefaultFilterEnabled):
    return ok(none(FilterServiceConf))

  return ok(
    some(
      FilterServiceConf(
        maxPeersToServe: b.maxPeersToServe.get(DefaultFilterMaxPeersToServe),
        subscriptionTimeout: b.subscriptionTimeout.get(DefaultFilterSubscriptionTimeout),
        maxCriteria: b.maxCriteria.get(DefaultFilterMaxCriteria),
      )
    )
  )
