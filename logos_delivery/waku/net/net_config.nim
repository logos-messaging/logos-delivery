{.push raises: [].}

import std/[sequtils, strutils, net], results, libp2p/[multiaddress, multicodec, wire]
import ../../waku/waku_core/peers
import ../waku_enr

type NetConfig* = object
  hostAddress*: MultiAddress
  clusterId*: uint16
  wsHostAddress*: Opt[MultiAddress]
  quicHostAddress*: Opt[MultiAddress]
  hostExtAddress*: Opt[MultiAddress]
  wsExtAddress*: Opt[MultiAddress]
  wssEnabled*: bool
  extIp*: Opt[IpAddress]
  extPort*: Opt[Port]
  dns4DomainName*: Opt[string]
  dnsNameServers*: seq[IpAddress]
  announcedAddresses*: seq[MultiAddress]
  extMultiAddrs*: seq[MultiAddress]
  enrMultiAddrs*: seq[MultiAddress]
  enrIp*: Opt[IpAddress]
  enrPort*: Opt[Port]
  discv5UdpPort*: Opt[Port]
  wakuFlags*: Opt[CapabilitiesBitfield]
  bindIp*: IpAddress
  bindPort*: Port

type NetConfigResult* = Result[NetConfig, string]

template ip4TcpEndPoint(address, port): MultiAddress =
  MultiAddress.init(address, tcpProtocol, port)

template dns4Ma(dns4DomainName: string): MultiAddress =
  MultiAddress.init("/dns4/" & dns4DomainName).tryGet()

template tcpPortMa(port: Port): MultiAddress =
  MultiAddress.init("/tcp/" & $port).tryGet()

template dns4TcpEndPoint(dns4DomainName: string, port: Port): MultiAddress =
  dns4Ma(dns4DomainName) & tcpPortMa(port)

template wsFlag(wssEnabled: bool): MultiAddress =
  if wssEnabled:
    MultiAddress.init("/wss").tryGet()
  else:
    MultiAddress.init("/ws").tryGet()

template udpPortMa(port: Port): MultiAddress =
  MultiAddress.init("/udp/" & $port).tryGet()

template quicFlag(): MultiAddress =
  MultiAddress.init("/quic-v1").tryGet()

template ipQuicEndPoint(address: IpAddress, port: Port): MultiAddress =
  MultiAddress.init(address, udpProtocol, port) & quicFlag()

template dns4QuicEndPoint(dns4DomainName: string, port: Port): MultiAddress =
  dns4Ma(dns4DomainName) & udpPortMa(port) & quicFlag()

proc formatListenAddress(inputMultiAdd: MultiAddress): MultiAddress =
  let inputStr = $inputMultiAdd
  # If MultiAddress contains "0.0.0.0", replace it for "127.0.0.1"
  return MultiAddress.init(inputStr.replace("0.0.0.0", "127.0.0.1")).get()

proc isWsAddress*(ma: MultiAddress): bool =
  let
    isWs = ma.contains(multiCodec("ws")).get()
    isWss = ma.contains(multiCodec("wss")).get()

  return isWs or isWss

proc isQuicAddress*(ma: MultiAddress): bool =
  return ma.hasProtocol("quic-v1")

proc isP2pTcpAddress*(ma: MultiAddress): bool =
  return ma.hasProtocol("tcp") and not ma.isWsAddress()

proc getPorts*(
    listenAddrs: seq[MultiAddress]
): Result[tuple[tcpPort, websocketPort, quicPort: Opt[Port]], string] =
  var tcpPort, websocketPort, quicPort = Opt.none(Port)

  for a in listenAddrs:
    if a.isWsAddress():
      if websocketPort.isNone():
        let wsAddress = initTAddress(a).valueOr:
          return err("getPorts wsAddr error:" & $error)
        websocketPort = Opt.some(wsAddress.port)
    elif a.isQuicAddress():
      if quicPort.isNone():
        let quicAddress = initTAddress(a).valueOr:
          return err("getPorts quicAddr error:" & $error)
        quicPort = Opt.some(quicAddress.port)
    elif tcpPort.isNone():
      let tcpAddress = initTAddress(a).valueOr:
        return err("getPorts tcpAddr error:" & $error)
      tcpPort = Opt.some(tcpAddress.port)

  return ok((tcpPort: tcpPort, websocketPort: websocketPort, quicPort: quicPort))

proc containsWsAddress(extMultiAddrs: seq[MultiAddress]): bool =
  return extMultiAddrs.filterIt(it.isWsAddress()).len > 0

proc containsQuicAddress(extMultiAddrs: seq[MultiAddress]): bool =
  return extMultiAddrs.filterIt(it.isQuicAddress()).len > 0

const DefaultWsBindPort = static(Port(8000))
# TODO: migrate to builder pattern with nested configs
proc init*(
    T: type NetConfig,
    bindIp: IpAddress,
    bindPort: Port,
    extIp = Opt.none(IpAddress),
    extPort = Opt.none(Port),
    extMultiAddrs = newSeq[MultiAddress](),
    extMultiAddrsOnly: bool = false,
    wsBindPort: Opt[Port] = Opt.some(DefaultWsBindPort),
    wsEnabled: bool = false,
    wssEnabled: bool = false,
    quicBindPort = Opt.none(Port),
    quicEnabled: bool = false,
    extQuicPort = Opt.none(Port),
    extWsPort = Opt.none(Port),
    natDiscovered: bool = false,
    dns4DomainName = Opt.none(string),
    discv5UdpPort = Opt.none(Port),
    clusterId: uint16 = 0,
    wakuFlags = Opt.none(CapabilitiesBitfield),
    dnsNameServers = @[parseIpAddress("1.1.1.1"), parseIpAddress("1.0.0.1")],
): NetConfigResult =
  ## Initialize and validate waku node network configuration

  # Bind addresses
  let hostAddress = ip4TcpEndPoint(bindIp, bindPort)

  var wsHostAddress = Opt.none(MultiAddress)
  if wsEnabled or wssEnabled:
    try:
      wsHostAddress = Opt.some(
        ip4TcpEndPoint(bindIp, wsbindPort.get(DefaultWsBindPort)) & wsFlag(wssEnabled)
      )
    except CatchableError:
      return err(getCurrentExceptionMsg())

  var quicHostAddress = Opt.none(MultiAddress)
  if quicEnabled:
    try:
      quicHostAddress = Opt.some(ipQuicEndPoint(bindIp, quicBindPort.get(bindPort)))
    except CatchableError:
      return err("failed to initialize quic address: " & getCurrentExceptionMsg())

  let enrIp =
    if extIp.isSome():
      extIp
    else:
      Opt.some(bindIp)
  let enrPort =
    if extPort.isSome():
      extPort
    else:
      Opt.some(bindPort)

  # Setup external addresses, if available
  var hostExtAddress, wsExtAddress, quicExtAddress = Opt.none(MultiAddress)

  if dns4DomainName.isSome():
    # Use dns4 for externally announced addresses
    try:
      hostExtAddress = Opt.some(dns4TcpEndPoint(dns4DomainName.get(), extPort.get()))
    except CatchableError:
      return err(getCurrentExceptionMsg())

    if wsHostAddress.isSome():
      try:
        wsExtAddress = Opt.some(
          dns4TcpEndPoint(dns4DomainName.get(), wsBindPort.get(DefaultWsBindPort)) &
            wsFlag(wssEnabled)
        )
      except CatchableError:
        return err(getCurrentExceptionMsg())

    if quicHostAddress.isSome():
      try:
        quicExtAddress = Opt.some(
          dns4QuicEndPoint(
            dns4DomainName.get(), extQuicPort.get(quicBindPort.get(bindPort))
          )
        )
      except CatchableError:
        return err("failed to set dns quic endpoint: " & getCurrentExceptionMsg())
  else:
    # No public domain name, use ext IP if available
    if extIp.isSome() and extPort.isSome():
      hostExtAddress = Opt.some(ip4TcpEndPoint(extIp.get(), extPort.get()))

      # With an operator-provided external IP the configured ports are used
      # as-is (the operator vouches for the endpoint). With a NAT-discovered
      # one (`natDiscovered`), each transport's external address is only
      # built from an actually mapped port — no guessing.
      if wsHostAddress.isSome():
        let wsPort =
          if natDiscovered:
            extWsPort
          else:
            Opt.some(extWsPort.get(wsBindPort.get(DefaultWsBindPort)))
        if wsPort.isSome():
          try:
            wsExtAddress =
              Opt.some(ip4TcpEndPoint(extIp.get(), wsPort.get()) & wsFlag(wssEnabled))
          except CatchableError:
            return err(getCurrentExceptionMsg())

      if quicHostAddress.isSome():
        let quicPort =
          if natDiscovered:
            extQuicPort
          else:
            Opt.some(extQuicPort.get(quicBindPort.get(bindPort)))
        if quicPort.isSome():
          try:
            quicExtAddress = Opt.some(ipQuicEndPoint(extIp.get(), quicPort.get()))
          except CatchableError:
            return err("failed to set ip quic endpoint: " & getCurrentExceptionMsg())

  var announcedAddresses = newSeq[MultiAddress]()

  if not extMultiAddrsOnly:
    if hostExtAddress.isSome():
      announcedAddresses.add(hostExtAddress.get())
    else:
      announcedAddresses.add(formatListenAddress(hostAddress))
        # We always have at least a bind address for the host

    if wsExtAddress.isSome():
      announcedAddresses.add(wsExtAddress.get())
    elif wsHostAddress.isSome() and not containsWsAddress(extMultiAddrs):
      # Only publish wsHostAddress if a WS address is not set in extMultiAddrs
      announcedAddresses.add(wsHostAddress.get())

    if quicExtAddress.isSome():
      announcedAddresses.add(quicExtAddress.get())
    elif quicHostAddress.isSome() and not containsQuicAddress(extMultiAddrs):
      announcedAddresses.add(formatListenAddress(quicHostAddress.get()))

  # External multiaddrs that the operator may have configured
  if extMultiAddrs.len > 0:
    announcedAddresses.add(extMultiAddrs)

  announcedAddresses = announcedAddresses.deduplicate()

  let
    # enrMultiaddrs are just addresses which cannot be represented in ENR, as described in
    # https://rfc.vac.dev/spec/31/#many-connection-types
    enrMultiaddrs = deduplicate(
      announcedAddresses.filterIt(
        it.hasProtocol("dns4") or it.hasProtocol("dns6") or it.hasProtocol("ws") or
          it.hasProtocol("wss") or it.hasProtocol("quic-v1")
      )
    )

  ok(
    NetConfig(
      hostAddress: hostAddress,
      clusterId: clusterId,
      wsHostAddress: wsHostAddress,
      quicHostAddress: quicHostAddress,
      hostExtAddress: hostExtAddress,
      wsExtAddress: wsExtAddress,
      extIp: extIp,
      extPort: extPort,
      wssEnabled: wssEnabled,
      dns4DomainName: dns4DomainName,
      dnsNameServers: dnsNameServers,
      announcedAddresses: announcedAddresses,
      extMultiAddrs: extMultiAddrs,
      enrMultiaddrs: enrMultiaddrs,
      enrIp: enrIp,
      enrPort: enrPort,
      discv5UdpPort: discv5UdpPort,
      bindIp: bindIp,
      bindPort: bindPort,
      wakuFlags: wakuFlags,
    )
  )
