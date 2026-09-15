## Waku layer API — health / connectivity.
{.push raises: [].}

import results, chronos, chronicles

import logos_delivery/waku/waku
import
  logos_delivery/waku/[
    node/health_monitor,
    node/health_monitor/online_monitor,
    node/health_monitor/protocol_health,
  ]

export protocol_health

proc isOnline*(self: Waku): Future[Result[bool, string]] {.async.} =
  try:
    return ok(self.healthMonitor.onlineMonitor.amIOnline())
  except CatchableError as e:
    return err(e.msg)

proc setConnectionStatusAdjuster*(self: Waku, adjuster: ConnectionStatusAdjuster) =
  ## Lets an upper layer tighten the connection status; call before start.
  if self.healthMonitor.isNil():
    return
  self.healthMonitor.adjustConnectionStatus = adjuster

func reportedProtocolHealth*(self: Waku, protocol: WakuProtocol): ProtocolHealth =
  ## The record the health monitor stored for `protocol` on its last pass.
  ## The last `EventProtocolHealthChange` for `protocol` carried the same
  ## status. Before the first pass the status is `NOT_MOUNTED`.
  if self.healthMonitor.isNil():
    return ProtocolHealth.init(protocol)
  return self.healthMonitor.reportedProtocolHealth(protocol)
