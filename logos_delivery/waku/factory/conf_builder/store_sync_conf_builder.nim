import chronicles, std/options, results
import ../waku_conf

logScope:
  topics = "waku conf builder store sync"

##################################
## Store Sync Config Builder ##
##################################
type StoreSyncConfBuilder* = object
  enabled*: Option[bool]

  rangeSec*: Option[uint32]
  intervalSec*: Option[uint32]
  relayJitterSec*: Option[uint32]

proc init*(T: type StoreSyncConfBuilder): StoreSyncConfBuilder =
  StoreSyncConfBuilder()

proc withEnabled*(b: var StoreSyncConfBuilder, enabled: bool) =
  b.enabled = some(enabled)

proc withRangeSec*(b: var StoreSyncConfBuilder, rangeSec: uint32) =
  b.rangeSec = some(rangeSec)

proc withIntervalSec*(b: var StoreSyncConfBuilder, intervalSec: uint32) =
  b.intervalSec = some(intervalSec)

proc withRelayJitterSec*(b: var StoreSyncConfBuilder, relayJitterSec: uint32) =
  b.relayJitterSec = some(relayJitterSec)

proc build*(b: StoreSyncConfBuilder): Result[Option[StoreSyncConf], string] =
  if not b.enabled.get(false):
    return ok(none(StoreSyncConf))

  if b.rangeSec.isNone():
    return err "store.rangeSec is not specified"
  if b.intervalSec.isNone():
    return err "store.intervalSec is not specified"
  if b.relayJitterSec.isNone():
    return err "store.relayJitterSec is not specified"

  return ok(
    some(
      StoreSyncConf(
        rangeSec: b.rangeSec.get(),
        intervalSec: b.intervalSec.get(),
        relayJitterSec: b.relayJitterSec.get(),
      )
    )
  )
