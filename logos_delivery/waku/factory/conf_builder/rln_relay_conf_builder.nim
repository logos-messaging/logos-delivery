import chronicles, results, stint, stew/endians2
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
  enabled*: Opt[bool]
  chainId*: Opt[UInt256]
  ethClientUrls*: Opt[seq[string]]
  ethContractAddress*: Opt[string]
  credIndex*: Opt[uint]
  credPassword*: Opt[string]
  credPath*: Opt[string]
  dynamic*: Opt[bool]
  epochSizeSec*: Opt[uint64]
  userMessageLimit*: Opt[uint64]

proc init*(T: type RlnConfBuilder): RlnConfBuilder =
  RlnConfBuilder()

proc withEnabled*(b: var RlnConfBuilder, enabled: bool) =
  b.enabled = Opt.some(enabled)

proc withChainId*(b: var RlnConfBuilder, chainId: uint | UInt256) =
  when chainId is uint:
    b.chainId = Opt.some(UInt256.fromBytesBE(chainId.toBytesBE()))
  else:
    b.chainId = Opt.some(chainId)

proc withCredIndex*(b: var RlnConfBuilder, credIndex: uint) =
  b.credIndex = Opt.some(credIndex)

proc withCredPassword*(b: var RlnConfBuilder, credPassword: string) =
  b.credPassword = Opt.some(credPassword)

proc withCredPath*(b: var RlnConfBuilder, credPath: string) =
  b.credPath = Opt.some(credPath)

proc withDynamic*(b: var RlnConfBuilder, dynamic: bool) =
  b.dynamic = Opt.some(dynamic)

proc withEthClientUrls*(b: var RlnConfBuilder, ethClientUrls: seq[string]) =
  b.ethClientUrls = Opt.some(ethClientUrls)

proc withEthContractAddress*(b: var RlnConfBuilder, ethContractAddress: string) =
  b.ethContractAddress = Opt.some(ethContractAddress)

proc withEpochSizeSec*(b: var RlnConfBuilder, epochSizeSec: uint64) =
  b.epochSizeSec = Opt.some(epochSizeSec)

proc withUserMessageLimit*(b: var RlnConfBuilder, userMessageLimit: uint64) =
  b.userMessageLimit = Opt.some(userMessageLimit)

proc build*(b: RlnConfBuilder): Result[Opt[RlnConf], string] =
  if not b.enabled.get(DefaultRlnRelayEnabled):
    return ok(Opt.none(RlnConf))

  if b.chainId.isNone():
    return err("RLN Relay Chain Id is not specified")

  let creds =
    if b.credPath.isSome() and b.credPassword.isSome():
      Opt.some(RlnCreds(path: b.credPath.get(), password: b.credPassword.get()))
    elif b.credPath.isSome() and b.credPassword.isNone():
      return err("RLN Relay Credential Password is not specified but path is")
    elif b.credPath.isNone() and b.credPassword.isSome():
      return err("RLN Relay Credential Path is not specified but password is")
    else:
      Opt.none(RlnCreds)

  if b.dynamic.isNone():
    return err("rlnRelay.dynamic is not specified")
  if b.ethClientUrls.get(newSeq[string](0)).len == 0:
    return err("rlnRelay.ethClientUrls is not specified")
  if b.ethContractAddress.get("") == "":
    return err("rlnRelay.ethContractAddress is not specified")
  return ok(
    Opt.some(
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
