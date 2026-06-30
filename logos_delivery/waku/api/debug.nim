## Waku layer API — debug / info operations.
{.push raises: [].}

import results, chronos, chronicles, metrics
import eth/p2p/discoveryv5/enr

import logos_delivery/waku/waku
import logos_delivery/waku/[waku_core, node/waku_node]

proc version*(self: Waku): Future[Result[string, string]] {.async.} =
  return ok(WakuNodeVersionString)

proc listenAddresses*(self: Waku): Future[Result[seq[string], string]] {.async.} =
  try:
    return ok(self.node.info().listenAddresses)
  except CatchableError as e:
    return err(e.msg)

proc myEnr*(self: Waku): Future[Result[string, string]] {.async.} =
  try:
    return ok(self.node.enr.toURI())
  except CatchableError as e:
    return err(e.msg)

proc myPeerId*(self: Waku): Future[Result[string, string]] {.async.} =
  try:
    return ok($self.node.peerId())
  except CatchableError as e:
    return err(e.msg)

proc metrics*(self: Waku): Future[Result[string, string]] {.async.} =
  {.gcsafe.}:
    try:
      return ok(defaultRegistry.toText())
    except CatchableError as e:
      return err(e.msg)
