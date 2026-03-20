import std/[options, strutils, sequtils]
import chronicles, results, chronos
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

proc withRetentionPolicies*(b: var StoreServiceConfBuilder, retentionPolicies: string) =
  b.retentionPolicies = retentionPolicies
    .multiReplace((" ", ""), ("\t", ""))
    .split(";")
    .mapIt(it.strip())
    .filterIt(it.len > 0)

proc withResume*(b: var StoreServiceConfBuilder, resume: bool) =
  b.resume = some(resume)

const ValidRetentionPolicyTypes = ["time", "capacity", "size"]

proc validateRetentionPolicies(policies: seq[string]): Result[void, string] =
  var seen: seq[string]

  for p in policies:
    let policy = p.multiReplace((" ", ""), ("\t", ""))
    let parts = policy.split(":", 1)
    if parts.len != 2 or parts[1] == "":
      return err(
        "invalid retention policy format: '" & policy & "', expected '<type>:<value>'"
      )

    let policyType = parts[0].toLowerAscii()
    if policyType notin ValidRetentionPolicyTypes:
      return err(
        "unknown retention policy type: '" & policyType &
          "', valid types are: time, capacity, size"
      )

    if policyType in seen:
      return err("duplicated retention policy type: '" & policyType & "'")

    seen.add(policyType)

  return ok()

proc build*(b: StoreServiceConfBuilder): Result[Option[StoreServiceConf], string] =
  if not b.enabled.get(false):
    return ok(none(StoreServiceConf))

  if b.dbUrl.get("") == "":
    return err "store.dbUrl is not specified"

  let storeSyncConf = b.storeSyncConf.build().valueOr:
    return err("Store Sync Conf failed to build")

  let retentionPolicies =
    if b.retentionPolicies.len == 0:
      @["time:" & $2.days.seconds]
    else:
      validateRetentionPolicies(b.retentionPolicies).isOkOr:
        return err("invalid retention policies: " & error)
      b.retentionPolicies

  return ok(
    some(
      StoreServiceConf(
        dbMigration: b.dbMigration.get(true),
        dbURl: b.dbUrl.get(),
        dbVacuum: b.dbVacuum.get(false),
        supportV2: b.supportV2.get(false),
        maxNumDbConnections: b.maxNumDbConnections.get(50),
        retentionPolicies: retentionPolicies,
        resume: b.resume.get(false),
        storeSyncConf: storeSyncConf,
      )
    )
  )
