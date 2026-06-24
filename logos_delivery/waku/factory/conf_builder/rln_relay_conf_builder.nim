import chronicles, std/options, results, stint, stew/endians2
import ../waku_conf

logScope:
  topics = "waku conf builder rln relay"

const
  DefaultRlnRelayEnabled*: bool = false
  DefaultRlnRelayEpochSizeSec*: uint64 = 1
  DefaultRlnRelayUserMessageLimit*: uint64 = 1

##############################
## RLN Relay Config Builder ##
##############################
type RlnConfBuilder* = object
  enabled*: Option[bool]
  chainId*: Option[UInt256]
  ethClientUrls*: Option[seq[string]]
  ethContractAddress*: Option[string]
  credIndex*: Option[uint]
  credPassword*: Option[string]
  credPath*: Option[string]
  dynamic*: Option[bool]
  epochSizeSec*: Option[uint64]
  userMessageLimit*: Option[uint64]

proc init*(T: type RlnConfBuilder): RlnConfBuilder =
  RlnConfBuilder()

proc withEnabled*(b: var RlnConfBuilder, enabled: bool) =
  b.enabled = some(enabled)

proc withChainId*(b: var RlnConfBuilder, chainId: uint | UInt256) =
  when chainId is uint:
    b.chainId = some(UInt256.fromBytesBE(chainId.toBytesBE()))
  else:
    b.chainId = some(chainId)

proc withCredIndex*(b: var RlnConfBuilder, credIndex: uint) =
  b.credIndex = some(credIndex)

proc withCredPassword*(b: var RlnConfBuilder, credPassword: string) =
  b.credPassword = some(credPassword)

proc withCredPath*(b: var RlnConfBuilder, credPath: string) =
  b.credPath = some(credPath)

proc withDynamic*(b: var RlnConfBuilder, dynamic: bool) =
  b.dynamic = some(dynamic)

proc withEthClientUrls*(b: var RlnConfBuilder, ethClientUrls: seq[string]) =
  b.ethClientUrls = some(ethClientUrls)

proc withEthContractAddress*(b: var RlnConfBuilder, ethContractAddress: string) =
  b.ethContractAddress = some(ethContractAddress)

proc withEpochSizeSec*(b: var RlnConfBuilder, epochSizeSec: uint64) =
  b.epochSizeSec = some(epochSizeSec)

proc withUserMessageLimit*(b: var RlnConfBuilder, userMessageLimit: uint64) =
  b.userMessageLimit = some(userMessageLimit)

proc build*(b: RlnConfBuilder): Result[Option[RlnConf], string] =
  if not b.enabled.get(DefaultRlnRelayEnabled):
    return ok(none(RlnConf))

  if b.chainId.isNone():
    return err("RLN Relay Chain Id is not specified")

  let creds =
    if b.credPath.isSome() and b.credPassword.isSome():
      some(RlnCreds(path: b.credPath.get(), password: b.credPassword.get()))
    elif b.credPath.isSome() and b.credPassword.isNone():
      return err("RLN Relay Credential Password is not specified but path is")
    elif b.credPath.isNone() and b.credPassword.isSome():
      return err("RLN Relay Credential Path is not specified but password is")
    else:
      none(RlnCreds)

  if b.dynamic.isNone():
    return err("rlnRelay.dynamic is not specified")
  if b.ethClientUrls.get(newSeq[string](0)).len == 0:
    return err("rlnRelay.ethClientUrls is not specified")
  if b.ethContractAddress.get("") == "":
    return err("rlnRelay.ethContractAddress is not specified")
  return ok(
    some(
      RlnConf(
        chainId: b.chainId.get(),
        credIndex: b.credIndex,
        creds: creds,
        dynamic: b.dynamic.get(),
        ethClientUrls: b.ethClientUrls.get(),
        ethContractAddress: b.ethContractAddress.get(),
        epochSizeSec: b.epochSizeSec.get(DefaultRlnRelayEpochSizeSec),
        userMessageLimit: b.userMessageLimit.get(DefaultRlnRelayUserMessageLimit),
      )
    )
  )
