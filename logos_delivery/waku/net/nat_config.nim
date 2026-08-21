{.push raises: [].}

## Maps a NAT strategy onto libp2p's NATService and provides its port mapper.
## The discv5 udp socket stays unmapped. A NATed node consumes discovery
## through outbound queries.

import std/net
import chronos, chronicles, results
import
  libp2p/services/natservice,
  libp2p/services/nat/[portmapper, upnp_mapper, natpmp_mapper]
import ./nat_strategy

export nat_strategy, natservice, portmapper

logScope:
  topics = "waku nat"

const NatDiscoveryTimeout = DefaultNatDiscoveryTimeoutMs.int64.milliseconds

proc natPortMapper*(strategy: NatStrategy): Opt[PortMapper] =
  ## The libp2p port mapper for NatUpnp or NatPmp.
  ## Resolve NatAny first with resolveNatStrategy.
  try:
    case strategy.kind
    of NatUpnp:
      Opt.some(PortMapper(UpnpMapper.new()))
    of NatPmp:
      Opt.some(PortMapper(NatPmpMapper.new()))
    of NatAny, NatNone, NatExtIp:
      Opt.none(PortMapper)
  except ResourceExhaustedError as e:
    error "Failed to construct NAT port mapper", err = e.msg
    Opt.none(PortMapper)

type ProbeMapperFactory* =
  proc(strategy: NatStrategy): Opt[PortMapper] {.gcsafe, raises: [].}
  ## Supplies the probe mapper for a strategy.
  ## Tests inject scripted mappers. Production uses natPortMapper.

proc probeAndClose(
    mapper: PortMapper, discoveryTimeout: Duration
): Future[Result[IpAddress, string]] {.async: (raises: [CancelledError]).} =
  ## Discover through the mapper, then close it before returning,
  ## cancellation included. close() joins the mapper's worker thread.
  ## With a silently dropping gateway a NAT-PMP worker retries past the
  ## timeout (libnatpmp schedule, 127.75 s ceiling) and the close holds
  ## startup for the remainder.
  try:
    return await mapper.discover(discoveryTimeout)
  finally:
    await mapper.close()

proc resolveNatStrategy*(
    strategy: NatStrategy,
    discoveryTimeout = NatDiscoveryTimeout,
    mapperFor: ProbeMapperFactory = nil,
): Future[NatStrategy] {.async: (raises: [CancelledError]).} =
  ## Resolve NatAny with one startup probe: UPnP first, then NAT-PMP.
  ## No answer resolves to NatNone. Every other kind passes through.
  ## Every constructed probe mapper is closed before this returns.
  if strategy.kind != NatAny:
    return strategy

  for candidate in [NatStrategy(kind: NatUpnp), NatStrategy(kind: NatPmp)]:
    let mapper = (
      if mapperFor.isNil():
        natPortMapper(candidate)
      else:
        mapperFor(candidate)
    ).valueOr:
      continue
    let found = await mapper.probeAndClose(discoveryTimeout)
    if found.isOk():
      info "resolved --nat any", winner = $candidate
      return candidate
    info "NAT gateway probe failed", strategy = $candidate, err = found.error

  warn "--nat any: no gateway answered discovery; continuing without port mapping"
  NatStrategy(kind: NatNone)

proc natConfig*(
    strategy: NatStrategy, discoveryTimeout = NatDiscoveryTimeout
): Opt[NATConfig] =
  ## The libp2p NATConfig for NatUpnp or NatPmp.
  ## The NatExtIp address is static state in NetConfig.
  case strategy.kind
  of NatUpnp:
    Opt.some(upnpConfig(discoveryTimeout = discoveryTimeout))
  of NatPmp:
    Opt.some(natPmpConfig(discoveryTimeout = discoveryTimeout))
  of NatAny, NatNone, NatExtIp:
    Opt.none(NATConfig)
