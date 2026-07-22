import std/[strutils, sequtils], chronicles, results, chronos
import ../waku_conf

logScope:
  topics = "waku conf builder store service"

const
  DefaultStoreEnabled: bool = false
  DefaultStoreDbMigration: bool = true
  DefaultStoreDbVacuum: bool = false
  DefaultStoreMaxNumDbConnections: int = 50
  DefaultStoreResume: bool = false
  DefaultStoreRetentionPolicy: string = "time:" & $2.days.seconds

##################################
## Store Service Config Builder ##
##################################
type StoreServiceConfBuilder* = object
  enabled*: Opt[bool]

  dbMigration*: Opt[bool]
  dbURl*: Opt[string]
  dbVacuum*: Opt[bool]
  maxNumDbConnections*: Opt[int]
  retentionPolicies*: seq[string]
  resume*: Opt[bool]

proc init*(T: type StoreServiceConfBuilder): StoreServiceConfBuilder =
  StoreServiceConfBuilder()

proc withEnabled*(b: var StoreServiceConfBuilder, enabled: bool) =
  b.enabled = Opt.some(enabled)

proc withDbMigration*(b: var StoreServiceConfBuilder, dbMigration: bool) =
  b.dbMigration = Opt.some(dbMigration)

proc withDbUrl*(b: var StoreServiceConfBuilder, dbUrl: string) =
  b.dbURl = Opt.some(dbUrl)

proc withDbVacuum*(b: var StoreServiceConfBuilder, dbVacuum: bool) =
  b.dbVacuum = Opt.some(dbVacuum)

proc withMaxNumDbConnections*(
    b: var StoreServiceConfBuilder, maxNumDbConnections: int
) =
  b.maxNumDbConnections = Opt.some(maxNumDbConnections)

proc withRetentionPolicies*(b: var StoreServiceConfBuilder, retentionPolicies: string) =
  b.retentionPolicies = retentionPolicies
    .multiReplace((" ", ""), ("\t", ""))
    .split(";")
    .mapIt(it.strip())
    .filterIt(it.len > 0)

proc withResume*(b: var StoreServiceConfBuilder, resume: bool) =
  b.resume = Opt.some(resume)

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

proc build*(b: StoreServiceConfBuilder): Result[Opt[StoreServiceConf], string] =
  if not b.enabled.get(DefaultStoreEnabled):
    return ok(Opt.none(StoreServiceConf))

  if b.dbUrl.get("") == "":
    return err "store.dbUrl is not specified"

  let retentionPolicies =
    if b.retentionPolicies.len == 0:
      @[DefaultStoreRetentionPolicy]
    else:
      validateRetentionPolicies(b.retentionPolicies).isOkOr:
        return err("invalid retention policies: " & error)
      b.retentionPolicies

  return ok(
    Opt.some(
      StoreServiceConf(
        dbMigration: b.dbMigration.get(DefaultStoreDbMigration),
        dbURl: b.dbUrl.get(),
        dbVacuum: b.dbVacuum.get(DefaultStoreDbVacuum),
        maxNumDbConnections: b.maxNumDbConnections.get(DefaultStoreMaxNumDbConnections),
        retentionPolicies: retentionPolicies,
        resume: b.resume.get(DefaultStoreResume),
      )
    )
  )
