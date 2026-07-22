import chronicles, results
import ../waku_conf, ../../common/databases/dburl

logScope:
  topics = "waku conf builder store sync"

const
  DefaultStoreSyncEnabled: bool = false
  DefaultStoreSyncDbUrl*: string = "sqlite://:memory:"

##################################
## Store Sync Config Builder ##
##################################
type StoreSyncConfBuilder* = object
  enabled*: Opt[bool]

  rangeSec*: Opt[uint32]
  intervalSec*: Opt[uint32]
  relayJitterSec*: Opt[uint32]
  dbUrl*: Opt[string]

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

proc withDbUrl*(b: var StoreSyncConfBuilder, dbUrl: string) =
  b.dbUrl = Opt.some(dbUrl)

proc build*(b: StoreSyncConfBuilder): Result[Opt[StoreSyncConf], string] =
  if not b.enabled.get(DefaultStoreSyncEnabled):
    return ok(Opt.none(StoreSyncConf))

  if b.rangeSec.isNone():
    return err "store.rangeSec is not specified"
  if b.intervalSec.isNone():
    return err "store.intervalSec is not specified"
  if b.relayJitterSec.isNone():
    return err "store.relayJitterSec is not specified"

  if b.rangeSec.get() == 0:
    return err "store sync range must be greater than 0"

  let dbUrl = b.dbUrl.get(DefaultStoreSyncDbUrl)
  let engine = getDbEngine(dbUrl).valueOr:
    return err "store sync dbUrl is invalid: " & error
  if engine != "sqlite" and engine != "postgres":
    return err "store sync dbUrl engine must be sqlite or postgres, got: " & engine

  return ok(
    Opt.some(
      StoreSyncConf(
        rangeSec: b.rangeSec.get(),
        intervalSec: b.intervalSec.get(),
        relayJitterSec: b.relayJitterSec.get(),
        dbUrl: dbUrl,
      )
    )
  )
