import
  chronicles,
  chronos,
  libp2p/crypto/crypto,
  libp2p/crypto/curve25519,
  libp2p/multiaddress,
  libp2p/nameresolving/dnsresolver,
  std/[sequtils, net],
  results

import logos_delivery/waku/[net/net_config, waku_enr, waku_core], ./waku_conf

proc tryBuildEnrRecord(
    conf: WakuConf, netConfig: NetConfig, multiaddrs: seq[MultiAddress]
): Result[enr.Record, string] =
  var enrBuilder = EnrBuilder.init(conf.nodeKey)

  enrBuilder.withIpAddressAndPorts(
    netConfig.enrIp, netConfig.enrPort, netConfig.discv5UdpPort
  )

  if netConfig.wakuFlags.isSome():
    enrBuilder.withWakuCapabilities(netConfig.wakuFlags.get())

  if multiaddrs.len > 0:
    enrBuilder.withMultiaddrs(multiaddrs)

  enrBuilder.withWakuRelaySharding(
    RelayShards(clusterId: conf.clusterId, shardIds: conf.subscribeShards)
  ).isOkOr:
    return err("could not initialize ENR with shards")

  let record = enrBuilder.build().valueOr:
    return err($error)

  return ok(record)

proc enrConfiguration*(
    conf: WakuConf, netConfig: NetConfig
): Result[enr.Record, string] =
  for retained in countdown(netConfig.enrMultiaddrs.len, 0):
    let multiaddrs = netConfig.enrMultiaddrs[0 ..< retained]
    let record = tryBuildEnrRecord(conf, netConfig, multiaddrs).valueOr:
      if retained > 0:
        warn "failed to create enr record, retrying with fewer multiaddrs",
          error = error,
          totalMultiaddrs = netConfig.enrMultiaddrs.len,
          retainedMultiaddrs = retained - 1,
          removedMultiaddr = multiaddrs[^1]
        continue

      error "failed to create enr record", error = error
      return err($error)

    if retained < netConfig.enrMultiaddrs.len:
      warn "created enr record after trimming multiaddrs",
        totalMultiaddrs = netConfig.enrMultiaddrs.len, retainedMultiaddrs = retained

    return ok(record)

  return err("failed to create enr record")

proc dnsResolve*(
    domain: string, dnsAddrsNameServers: seq[IpAddress]
): Future[Result[string, string]] {.async.} =
  # Use conf's DNS servers
  var nameServers: seq[TransportAddress]
  for ip in dnsAddrsNameServers:
    nameServers.add(initTAddress(ip, Port(53))) # Assume all servers use port 53

  let dnsResolver = DnsResolver.new(nameServers)

  # Resolve domain IP
  let resolved = await dnsResolver.resolveIp(domain, 0.Port, Domain.AF_UNSPEC)

  if resolved.len > 0:
    return ok(resolved[0].host) # Use only first answer
  else:
    return err("Could not resolve IP from DNS: empty response")

# TODO: Reduce number of parameters, can be done once the same is done on Netconfig.init
proc networkConfiguration*(
    clusterId: uint16,
    conf: EndpointConf,
    discv5Conf: Opt[Discv5Conf],
    webSocketConf: Opt[WebSocketConf],
    quicConf: Opt[QuicConf],
    wakuFlags: CapabilitiesBitfield,
    dnsAddrsNameServers: seq[IpAddress],
    natExtIp = Opt.none(IpAddress),
    extTcpPort = Opt.none(Port),
    extUdpPort = Opt.none(Port),
): Future[NetConfigResult] {.async.} =
  let tcpBindPort = conf.p2pTcpPort

  let (quicEnabled, quicBindPort) =
    if quicConf.isSome():
      let qConf = quicConf.get()
      (true, Opt.some(qConf.port))
    else:
      (false, Opt.none(Port))

  ## External IP/ports as far as they can be known at this point: `extip:` is
  ## static configuration, while UPnP/NAT-PMP mappings are performed by the
  ## switch's NATService at startup; the caller passes their results in
  ## (`natExtIp`/`extTcpPort`/`extUdpPort`) when recomputing the config on a
  ## running node.
  var extIp = natExtIp
  if extIp.isNone() and conf.natStrategy.kind == NatExtIp:
    extIp = Opt.some(conf.natStrategy.extIp)

  let
    discv5UdpPort =
      if discv5Conf.isSome():
        Opt.some(discv5Conf.get().udpPort)
      else:
        Opt.none(Port)

    ## The bind-port fallback below assumes the operator vouches for the
    ## external endpoint (`extip:` implies a manual port mapping, dns4 a name
    ## that resolves to this node). For a NAT-discovered external IP the
    ## mapped ports are authoritative instead: a transport without a mapping
    ## in place has no external endpoint and must not announce a guessed one.
    natDiscovered = natExtIp.isSome()

    extPort =
      if natDiscovered:
        extTcpPort
      elif (extIp.isSome() or conf.dns4DomainName.isSome()) and extTcpPort.isNone():
        Opt.some(tcpBindPort)
      else:
        extTcpPort

    extQuicPort =
      if natDiscovered:
        extUdpPort
      elif (extIp.isSome() or conf.dns4DomainName.isSome()) and extUdpPort.isNone():
        quicBindPort
      else:
        extUdpPort

  # Resolve and use DNS domain IP
  if conf.dns4DomainName.isSome() and extIp.isNone():
    try:
      let dns = (await dnsResolve(conf.dns4DomainName.get(), dnsAddrsNameServers)).valueOr:
        return err($error) # Pass error down the stack

      extIp = Opt.some(parseIpAddress(dns))
    except CatchableError:
      return
        err("Could not update extIp to resolved DNS IP: " & getCurrentExceptionMsg())

  let (wsEnabled, wsBindPort, wssEnabled) =
    if webSocketConf.isSome:
      let wsConf = webSocketConf.get()
      (true, Opt.some(wsConf.port), wsConf.secureConf.isSome)
    else:
      (false, Opt.none(Port), false)

  # Wrap in none because NetConfig does not have a default constructor
  # TODO: We could change bindIp in NetConfig to be something less restrictive
  # than IpAddress, which doesn't allow default construction
  let netConfigRes = NetConfig.init(
    clusterId = clusterId,
    bindIp = conf.p2pListenAddress,
    bindPort = tcpBindPort,
    extIp = extIp,
    extPort = extPort,
    extMultiAddrs = conf.extMultiAddrs,
    extMultiAddrsOnly = conf.extMultiAddrsOnly,
    wsBindPort = wsBindPort,
    wsEnabled = wsEnabled,
    wssEnabled = wssEnabled,
    quicBindPort = quicBindPort,
    quicEnabled = quicEnabled,
    extQuicPort = extQuicPort,
    dns4DomainName = conf.dns4DomainName,
    discv5UdpPort = discv5UdpPort,
    wakuFlags = Opt.some(wakuFlags),
    dnsNameServers = dnsAddrsNameServers,
  )

  return netConfigRes
