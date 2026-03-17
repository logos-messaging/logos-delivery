import chronicles, std/options, results, chronos
import ../waku_conf, ./store_sync_conf_builder

logScope:
  topics = "waku conf builder store service"

##################################
## Store Service Config Builder ##
##################################
type StoreServiceConfBuilder* = object
  enabled*: Option[bool]

  dbMigration*: Option[bool]
  dbURl*: Option[string]
  dbVacuum*: Option[bool]
  supportV2*: Option[bool]
  maxNumDbConnections*: Option[int]
  retentionPolicies*: seq[string]
  resume*: Option[bool]
  storeSyncConf*: StoreSyncConfBuilder

proc init*(T: type StoreServiceConfBuilder): StoreServiceConfBuilder =
  StoreServiceConfBuilder(storeSyncConf: StoreSyncConfBuilder.init())

proc withEnabled*(b: var StoreServiceConfBuilder, enabled: bool) =
  b.enabled = some(enabled)

proc withDbMigration*(b: var StoreServiceConfBuilder, dbMigration: bool) =
  b.dbMigration = some(dbMigration)

proc withDbUrl*(b: var StoreServiceConfBuilder, dbUrl: string) =
  b.dbURl = some(dbUrl)

proc withDbVacuum*(b: var StoreServiceConfBuilder, dbVacuum: bool) =
  b.dbVacuum = some(dbVacuum)

proc withSupportV2*(b: var StoreServiceConfBuilder, supportV2: bool) =
  b.supportV2 = some(supportV2)

proc withMaxNumDbConnections*(
    b: var StoreServiceConfBuilder, maxNumDbConnections: int
) =
  b.maxNumDbConnections = some(maxNumDbConnections)

proc withRetentionPolicies*(
    b: var StoreServiceConfBuilder, retentionPolicies: seq[string]
) =
  b.retentionPolicies = retentionPolicies

proc withResume*(b: var StoreServiceConfBuilder, resume: bool) =
  b.resume = some(resume)

proc build*(b: StoreServiceConfBuilder): Result[Option[StoreServiceConf], string] =
  if not b.enabled.get(false):
    return ok(none(StoreServiceConf))

  if b.dbUrl.get("") == "":
    return err "store.dbUrl is not specified"

  let storeSyncConf = b.storeSyncConf.build().valueOr:
    return err("Store Sync Conf failed to build")

  return ok(
    some(
      StoreServiceConf(
        dbMigration: b.dbMigration.get(true),
        dbURl: b.dbUrl.get(),
        dbVacuum: b.dbVacuum.get(false),
        supportV2: b.supportV2.get(false),
        maxNumDbConnections: b.maxNumDbConnections.get(50),
        retentionPolicies:
          if b.retentionPolicies.len == 0:
            @["time:" & $2.days.seconds]
          else:
            b.retentionPolicies,
        resume: b.resume.get(false),
        storeSyncConf: storeSyncConf,
      )
    )
  )
