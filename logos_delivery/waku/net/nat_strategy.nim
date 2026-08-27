{.push raises: [].}

## NatStrategy holds the user intent of --nat.
## nat_config maps a strategy onto the NATService.

import std/[net, strutils]
import results

type
  NatStrategyKind* {.pure.} = enum
    NatNone
    NatAny
    NatUpnp
    NatPmp
    NatExtIp

  NatStrategy* = object
    case kind*: NatStrategyKind
    of NatExtIp:
      extIp*: IpAddress
    else:
      discard

func `$`*(strategy: NatStrategy): string =
  case strategy.kind
  of NatNone:
    return "none"
  of NatAny:
    return "any"
  of NatUpnp:
    return "upnp"
  of NatPmp:
    return "pmp"
  of NatExtIp:
    return "extip:" & $strategy.extIp

func parseNatStrategy*(value: string): Result[NatStrategy, string] =
  let normalized = value.strip().toLowerAscii()
  case normalized
  of "any":
    return ok(NatStrategy(kind: NatAny))
  of "none":
    return ok(NatStrategy(kind: NatNone))
  of "upnp":
    return ok(NatStrategy(kind: NatUpnp))
  of "pmp":
    return ok(NatStrategy(kind: NatPmp))
  else:
    const ExtIpPrefix = "extip:"
    if not normalized.startsWith(ExtIpPrefix):
      return err("not a valid NAT mechanism: " & value)

    let ipString = normalized[ExtIpPrefix.len ..^ 1]
    let ip =
      try:
        parseIpAddress(ipString)
      except ValueError:
        return err("not a valid IP address: " & ipString)

    ok(NatStrategy(kind: NatExtIp, extIp: ip))

const DefaultNatDiscoveryTimeoutMs* = 1000'u32
  ## Node start awaits gateway discovery. miniupnpc waits the full timeout
  ## per SSDP round, so one second bounds the worst stall.
