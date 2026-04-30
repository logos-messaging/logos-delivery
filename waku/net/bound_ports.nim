{.push raises: [].}

import std/[json, options]

type BoundPorts* {.requiresInit.} = object
  ## Set by the factory once each service has bound to a port.
  tcp*: Option[uint16]
  webSocket*: Option[uint16]
  rest*: Option[uint16]
  discv5Udp*: Option[uint16]
  metrics*: Option[uint16]

proc init*(T: type BoundPorts): BoundPorts =
  BoundPorts(
    tcp: none(uint16),
    webSocket: none(uint16),
    rest: none(uint16),
    discv5Udp: none(uint16),
    metrics: none(uint16),
  )

proc toJsonString*(p: BoundPorts): string =
  var obj = newJObject()
  for name, value in fieldPairs(p):
    if value.isSome():
      obj[name] = %value.get()
  return $obj
