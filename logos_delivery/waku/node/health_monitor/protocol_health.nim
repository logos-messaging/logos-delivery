import std/[options, strformat]
import ./health_status
import waku/common/waku_protocol

export waku_protocol

type ProtocolHealth* = object
  protocol*: string
  health*: HealthStatus
  desc*: Option[string] ## describes why a certain protocol is considered `NOT_READY`

proc notReady*(p: var ProtocolHealth, desc: string): ProtocolHealth =
  p.health = HealthStatus.NOT_READY
  p.desc = some(desc)
  return p

proc ready*(p: var ProtocolHealth): ProtocolHealth =
  p.health = HealthStatus.READY
  p.desc = none[string]()
  return p

proc notMounted*(p: var ProtocolHealth): ProtocolHealth =
  p.health = HealthStatus.NOT_MOUNTED
  p.desc = none[string]()
  return p

proc synchronizing*(p: var ProtocolHealth): ProtocolHealth =
  p.health = HealthStatus.SYNCHRONIZING
  p.desc = none[string]()
  return p

proc initializing*(p: var ProtocolHealth): ProtocolHealth =
  p.health = HealthStatus.INITIALIZING
  p.desc = none[string]()
  return p

proc shuttingDown*(p: var ProtocolHealth): ProtocolHealth =
  p.health = HealthStatus.SHUTTING_DOWN
  p.desc = none[string]()
  return p

proc `$`*(p: ProtocolHealth): string =
  return fmt"protocol: {p.protocol}, health: {p.health}, description: {p.desc}"

proc init*(p: typedesc[ProtocolHealth], protocol: WakuProtocol): ProtocolHealth =
  return ProtocolHealth(
    protocol: $protocol, health: HealthStatus.NOT_MOUNTED, desc: none[string]()
  )
