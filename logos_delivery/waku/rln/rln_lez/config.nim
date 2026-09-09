{.push raises: [].}

## The RLN plugin carries no configuration: the host — the application
## embedding this library over its C ABI and installing the plugin, i.e.
## logos-delivery-module — owns the backend's parameters and never hands them
## to the library. Only the node-local fatal error handler remains, which is
## not RLN configuration.

import logos_delivery/waku/common/error_handling

type WakuRlnLezConfig* = object
  onFatalErrorAction*: OnFatalErrorHandler

{.pop.}
