{.push raises: [].}

## The RLN plugin carries no configuration: the host owns the backend's
## parameters and never hands them to the library. Only the node-local fatal
## error handler remains, which is not RLN configuration.

import logos_delivery/waku/common/error_handling

type WakuRlnLezConfig* = object
  onFatalErrorAction*: OnFatalErrorHandler

{.pop.}
