{.push raises: [].}

## The RLN plugin carries no backend configuration: the host — the application
## embedding this library over its C ABI and installing the plugin, i.e.
## logos-delivery-module — owns the backend's parameters and never hands them
## to the library. What remains here is node-local: the fatal error handler,
## and the temporary phase-in switch the host sets over FFI
## (`logosdelivery_rln_disable_validation`).

import logos_delivery/waku/common/error_handling

type WakuRlnLezConfig* = object
  onFatalErrorAction*: OnFatalErrorHandler
  disableValidation*: bool
    ## Temporary RLN phase-in switch: when true, published messages still get
    ## proofs attached, but received messages are not validated — they pass
    ## through unchecked. Remove once the whole network attaches proofs and
    ## validation is enabled everywhere.

{.pop.}
