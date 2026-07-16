import chronicles, results
import ../waku_conf

logScope:
  topics = "waku conf builder store sync"

const DefaultStoreSyncEnabled: bool = false

##################################
## Store Sync Config Builder ##
##################################
type StoreSyncConfBuilder* = object
  enabled*: Opt[bool]

  rangeSec*: Opt[uint32]
  intervalSec*: Opt[uint32]
  relayJitterSec*: Opt[uint32]

proc init*(T: type StoreSyncConfBuilder): StoreSyncConfBuilder =
  StoreSyncConfBuilder()

proc withEnabled*(b: var StoreSyncConfBuilder, enabled: bool) =
  b.enabled = Opt.some(enabled)

proc withRangeSec*(b: var StoreSyncConfBuilder, rangeSec: uint32) =
  b.rangeSec = Opt.some(rangeSec)

proc withIntervalSec*(b: var StoreSyncConfBuilder, intervalSec: uint32) =
  b.intervalSec = Opt.some(intervalSec)

proc withRelayJitterSec*(b: var StoreSyncConfBuilder, relayJitterSec: uint32) =
  b.relayJitterSec = Opt.some(relayJitterSec)

proc build*(b: StoreSyncConfBuilder): Result[Opt[StoreSyncConf], string] =
  if not b.enabled.get(DefaultStoreSyncEnabled):
    return ok(Opt.none(StoreSyncConf))

  if b.rangeSec.isNone():
    return err "store.rangeSec is not specified"
  if b.intervalSec.isNone():
    return err "store.intervalSec is not specified"
  if b.relayJitterSec.isNone():
    return err "store.relayJitterSec is not specified"

  return ok(
    Opt.some(
      StoreSyncConf(
        rangeSec: b.rangeSec.get(),
        intervalSec: b.intervalSec.get(),
        relayJitterSec: b.relayJitterSec.get(),
      )
    )
  )
