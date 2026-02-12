{.push raises: [].}

import ./health_status, ./connection_status, ./protocol_health

type HealthReport* = object
  ## Rest API type returned for /health endpoint
  ##
  nodeHealth*: HealthStatus # legacy "READY" health indicator
  connectionStatus*: ConnectionStatus # new "Connected" health indicator
  protocolsHealth*: seq[ProtocolHealth]
