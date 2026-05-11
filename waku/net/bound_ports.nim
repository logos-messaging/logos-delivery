{.push raises: [].}

import std/json

type BoundPorts* {.requiresInit.} = object
  ## Set by the factory once each service has bound to a port.
  ## A value of 0 means the service was not enabled or did not bind.
  tcp*: uint16
  webSocket*: uint16
  rest*: uint16
  discv5Udp*: uint16
  metrics*: uint16

proc init*(T: type BoundPorts): BoundPorts =
  return BoundPorts(
    tcp: 0'u16, webSocket: 0'u16, rest: 0'u16, discv5Udp: 0'u16, metrics: 0'u16
  )

proc `$`*(p: BoundPorts): string =
  return $(%*p)
