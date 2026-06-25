## Waku layer API — health / connectivity.
{.push raises: [].}

import results, chronos, chronicles

import logos_delivery/waku/waku
import logos_delivery/waku/[node/health_monitor, node/health_monitor/online_monitor]

proc isOnline*(self: Waku): bool =
  return self.healthMonitor.onlineMonitor.amIOnline()
