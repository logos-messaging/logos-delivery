{.push raises: [].}

## RLN-LEZ backend configuration: membership scope and epoch parameters only.
## The external module owns keystore, credentials, and registry connectivity.

import logos_delivery/waku/common/error_handling

type RlnLezConf* = object of RootObj
  registryId*: string ## CAIP-10 account identifier selecting the registry deployment.
  identifier*: array[32, byte]
    ## Per-application RLN identifier, mixed into the external nullifier.
  epochSizeSec*: uint64
  userMessageLimit*: uint64
  registryOptionsJson*: string
    ## Flat JSON object of registry-specific registration options passed
    ## verbatim to the external RLN module's register() (e.g. funding or
    ## delegation options for the logos namespace). "{}" when unset.

type WakuRlnLezConfig* = object of RlnLezConf
  onFatalErrorAction*: OnFatalErrorHandler

{.pop.}
