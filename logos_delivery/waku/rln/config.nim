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

type WakuRlnConfig* = object of RlnConf
  onFatalErrorAction*: OnFatalErrorHandler
