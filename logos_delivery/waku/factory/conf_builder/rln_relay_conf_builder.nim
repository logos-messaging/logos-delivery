import chronicles, std/options, results, stint, stew/endians2
import ../waku_conf

logScope:
  topics = "waku conf builder rln relay"

##############################
## RLN Relay Config Builder ##
##############################
type RlnRelayConfBuilder* = object
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

proc init*(T: type RlnRelayConfBuilder): RlnRelayConfBuilder =
  RlnRelayConfBuilder()

proc withEnabled*(b: var RlnRelayConfBuilder, enabled: bool) =
  b.enabled = some(enabled)

proc withChainId*(b: var RlnRelayConfBuilder, chainId: uint | UInt256) =
  when chainId is uint:
    b.chainId = some(UInt256.fromBytesBE(chainId.toBytesBE()))
  else:
    b.chainId = some(chainId)

proc withCredIndex*(b: var RlnRelayConfBuilder, credIndex: uint) =
  b.credIndex = some(credIndex)

proc withCredPassword*(b: var RlnRelayConfBuilder, credPassword: string) =
  b.credPassword = some(credPassword)

proc withCredPath*(b: var RlnRelayConfBuilder, credPath: string) =
  b.credPath = some(credPath)

proc withDynamic*(b: var RlnRelayConfBuilder, dynamic: bool) =
  b.dynamic = some(dynamic)

proc withEthClientUrls*(b: var RlnRelayConfBuilder, ethClientUrls: seq[string]) =
  b.ethClientUrls = some(ethClientUrls)

proc withEthContractAddress*(b: var RlnRelayConfBuilder, ethContractAddress: string) =
  b.ethContractAddress = some(ethContractAddress)

proc withEpochSizeSec*(b: var RlnRelayConfBuilder, epochSizeSec: uint64) =
  b.epochSizeSec = some(epochSizeSec)

proc withUserMessageLimit*(b: var RlnRelayConfBuilder, userMessageLimit: uint64) =
  b.userMessageLimit = some(userMessageLimit)

proc build*(b: RlnRelayConfBuilder): Result[Option[RlnRelayConf], string] =
  if not b.enabled.get(false):
    return ok(none(RlnRelayConf))

  if b.chainId.isNone():
    return err("RLN Relay Chain Id is not specified")

  let creds =
    if b.credPath.isSome() and b.credPassword.isSome():
      some(RlnRelayCreds(path: b.credPath.get(), password: b.credPassword.get()))
    elif b.credPath.isSome() and b.credPassword.isNone():
      return err("RLN Relay Credential Password is not specified but path is")
    elif b.credPath.isNone() and b.credPassword.isSome():
      return err("RLN Relay Credential Path is not specified but password is")
    else:
      none(RlnRelayCreds)

  if b.dynamic.isNone():
    return err("rlnRelay.dynamic is not specified")
  if b.ethClientUrls.get(newSeq[string](0)).len == 0:
    return err("rlnRelay.ethClientUrls is not specified")
  if b.ethContractAddress.get("") == "":
    return err("rlnRelay.ethContractAddress is not specified")
  if b.epochSizeSec.isNone():
    return err("rlnRelay.epochSizeSec is not specified")
  if b.userMessageLimit.isNone():
    return err("rlnRelay.userMessageLimit is not specified")

  return ok(
    some(
      RlnRelayConf(
        chainId: b.chainId.get(),
        credIndex: b.credIndex,
        creds: creds,
        dynamic: b.dynamic.get(),
        ethClientUrls: b.ethClientUrls.get(),
        ethContractAddress: b.ethContractAddress.get(),
        epochSizeSec: b.epochSizeSec.get(),
        userMessageLimit: b.userMessageLimit.get(),
      )
    )
  )
