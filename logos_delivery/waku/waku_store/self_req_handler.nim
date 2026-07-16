##
## This file is aimed to attend the requests that come directly
## from the 'self' node. It is expected to attend the store requests that
## come from REST-store endpoint when those requests don't indicate
## any store-peer address.
##
## Notice that the REST-store requests normally assume that the REST
## server is acting as a store-client. In this module, we allow that
## such REST-store node can act as store-server as well by retrieving
## its own stored messages. The typical use case for that is when
## using `nwaku-compose`, which spawn a Waku node connected to a local
## database, and the user is interested in retrieving the messages
## stored by that local store node.
##

import results, chronos
import ./protocol, ./common

proc handleSelfStoreRequest*(
    self: WakuStore, req: StoreQueryRequest
): Future[WakuStoreResult[StoreQueryResponse]] {.async.} =
  ## Handles the store requests made by the node to itself.
  ## Normally used in REST-store requests

  let handlerResult = catch:
    await self.requestHandler(req)

  let resResult = handlerResult.valueOr:
    return err("exception in handleSelfStoreRequest: " & error.msg)

  let res = resResult.valueOr:
    return err("error in handleSelfStoreRequest: " & $error)

  return ok(res)
