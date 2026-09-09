## Waku layer API — health / connectivity.
{.push raises: [].}

import std/strutils
import results, chronos, chronicles

import logos_delivery/waku/waku
import logos_delivery/waku/common/waku_protocol
import logos_delivery/waku/[node/health_monitor, node/health_monitor/online_monitor]

proc isOnline*(self: Waku): Future[Result[bool, string]] {.async.} =
  try:
    return ok(self.healthMonitor.onlineMonitor.amIOnline())
  except CatchableError as e:
    return err(e.msg)

proc receivesLive*(self: Waku): bool =
  ## True while relay or the filter client reports a peer, so live messages
  ## reach the node. Read from the health monitor's last report.
  if self.healthMonitor.isNil():
    return false
  for p in self.healthMonitor.getSyncNodeHealthReport().protocolsHealth:
    if p.health != HealthStatus.READY:
      continue
    let kind =
      try:
        parseEnum[WakuProtocol](p.protocol)
      except ValueError:
        continue
    if kind in RelayProtocols or kind in FilterClientProtocols:
      return true
  false
