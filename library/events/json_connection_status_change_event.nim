{.push raises: [].}

import system, std/json
import ./json_base_event
import ../../waku/node/health_monitor/connection_status

type JsonConnectionStatusChangeEvent* = ref object of JsonEvent
  status*: ConnectionStatus

proc new*(
    T: type JsonConnectionStatusChangeEvent, status: ConnectionStatus
): T =
  return JsonConnectionStatusChangeEvent(
    eventType: "node_health_change",
    status: status
  )

method `$`*(event: JsonConnectionStatusChangeEvent): string =
  $(%*event)
