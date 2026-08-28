{.push raises: [].}

import results, stint

import logos_delivery/waku/common/error_handling

type RlnCreds* {.requiresInit.} = object
  path*: string
  password*: string

type RlnConf* = object of RootObj
  # TODO: severals parameters are only needed when it's dynamic
  # change the config to either nest or use enum/type variant so it's obvious
  # and then it can be set to `requiresInit`
  dynamic*: bool
  credIndex*: Opt[uint]
  ethContractAddress*: string
  ethClientUrls*: seq[string]
  chainId*: UInt256
  creds*: Opt[RlnCreds]
  epochSizeSec*: uint64
  userMessageLimit*: uint64
  ethPrivateKey*: Opt[string]
  # TODO: fold into the enum/type variant above; when `lez` is set only
  # `registryId`/`identifier` select the registry and the eth* fields are unused
  lez*: bool
  registryId*: string
  identifier*: array[32, byte]
  registryOptionsJson*: string
    ## Flat JSON object of registry-specific registration options passed
    ## verbatim to the external RLN module's register() (e.g. funding or
    ## delegation options for the logos namespace). "{}" when unset.

type WakuRlnConfig* = object of RlnConf
  onFatalErrorAction*: OnFatalErrorHandler

type RlnLezConf* = object of RootObj
  # TODO: severals parameters are only needed when it's dynamic
  # change the config to either nest or use enum/type variant so it's obvious
  # and then it can be set to `requiresInit`
  registryId*: string
  identifier*: array[32, byte]
  creds*: Opt[RlnCreds]
  epochSizeSec*: uint64
  userMessageLimit*: uint64

type WakuRlnLezConfig* = object of RlnLezConf
  onFatalErrorAction*: OnFatalErrorHandler
