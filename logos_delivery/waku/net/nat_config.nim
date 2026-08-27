{.push raises: [].}

## Maps a NAT strategy onto libp2p's NATService and provides its port mapper.
## The discv5 udp socket stays unmapped. A NATed node consumes discovery
## through outbound queries.

import chronos, chronicles, results
import libp2p/services/natservice, libp2p/services/nat/[portmapper, plum_mapper]
import ./nat_strategy

export nat_strategy, natservice, portmapper

logScope:
  topics = "waku nat"

const NatDiscoveryTimeout = DefaultNatDiscoveryTimeoutMs.int64.milliseconds

proc natPortMapper*(strategy: NatStrategy): Opt[PortMapper] =
  ## Build the libplum mapper for the requested protocol selection.
  let filter =
    case strategy.kind
    of NatStrategyKind.NatUpnp:
      ProtocolFilter.UPnP
    of NatStrategyKind.NatPmp:
      ProtocolFilter.PCP
    of NatStrategyKind.NatAny:
      ProtocolFilter.Any
    of NatStrategyKind.NatNone, NatStrategyKind.NatExtIp:
      return Opt.none(PortMapper)

  let mapper = PlumMapper.new(filter = filter).valueOr:
    error "Failed to construct NAT port mapper", err = error
    return Opt.none(PortMapper)
  Opt.some(PortMapper(mapper))

proc resolveNatStrategy*(
    strategy: NatStrategy
): Future[NatStrategy] {.async: (raises: []).} =
  ## Libplum selects the available gateway protocol when NatAny is configured.
  return strategy

proc natConfig*(
    strategy: NatStrategy, discoveryTimeout = NatDiscoveryTimeout
): Opt[NATConfig] =
  ## The libp2p NATConfig for automatic or restricted protocol selection.
  ## The NatExtIp address is static state in NetConfig.
  case strategy.kind
  of NatStrategyKind.NatAny:
    Opt.some(natservice.natConfig(discoveryTimeout = discoveryTimeout))
  of NatStrategyKind.NatUpnp:
    Opt.some(upnpConfig(discoveryTimeout = discoveryTimeout))
  of NatStrategyKind.NatPmp:
    Opt.some(natPmpConfig(discoveryTimeout = discoveryTimeout))
  of NatStrategyKind.NatNone, NatStrategyKind.NatExtIp:
    Opt.none(NATConfig)
