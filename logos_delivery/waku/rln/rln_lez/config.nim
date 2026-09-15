{.push raises: [].}

## The RLN plugin carries no backend configuration: the host — the application
## embedding this library over its C ABI and installing the plugin, i.e.
## logos-delivery-module — owns the backend's parameters and never hands them
## to the library. What remains here is node-local: the fatal error handler,
## and the temporary phase-in switch set via the node configuration
## (`rln-disable-validation`).

import logos_delivery/waku/common/error_handling

type WakuRlnLezConfig* = object
  onFatalErrorAction*: OnFatalErrorHandler
  disableValidation*: bool
    ## When true, published messages still get proofs attached, but received
    ## messages are not validated — they pass through unchecked.

{.pop.}
