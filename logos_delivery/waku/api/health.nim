## Waku layer API — health / connectivity.
{.push raises: [].}

import results, chronos, chronicles

import logos_delivery/waku/waku
import logos_delivery/waku/[node/health_monitor, node/health_monitor/online_monitor]

proc isOnline*(self: Waku): Future[Result[bool, string]] {.async.} =
  try:
    return ok(self.healthMonitor.onlineMonitor.amIOnline())
  except CatchableError as e:
    return err(e.msg)

proc setMixRequired*(self: Waku, required: bool) =
  ## Tells the health monitor whether mix readiness gates connectivity.
  if isNil(self.healthMonitor):
    return
  self.healthMonitor.setMixRequired(required)
