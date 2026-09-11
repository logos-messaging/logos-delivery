# Waku Switch utils.
{.push raises: [].}

import
  std/net,
  results,
  chronos,
  chronos/transports/osnet,
  chronicles,
  eth/keys,
  libp2p/crypto/crypto,
  libp2p/protocols/pubsub/gossipsub,
  libp2p/protocols/rendezvous,
  libp2p/protocols/connectivity/relay/relay,
  libp2p/nameresolving/nameresolver,
  libp2p/builders,
  libp2p/switch,
  libp2p/transports/[transport, tcptransport, wstransport],
  libp2p/utils/opt
import ./delivery_dialer

# override nim-libp2p default value (which is also 1)
const MaxConnectionsPerPeer* = 1

const MaxConnections* = 50

logScope:
  topics = "waku switch"

const
  ## The destinations a route lookup probes. No traffic is sent.
  Ipv4Probe = parseIpAddress("8.8.8.8")
  Ipv6Probe = parseIpAddress("2001:4860:4860::8888")
  Ipv4Loopback = parseIpAddress("127.0.0.1")

proc primaryInterfaceProvider*(
    addrFamily: AddressFamily
): seq[InterfaceAddress] {.gcsafe, raises: [].} =
  ## One address per IP family for a wildcard bind: the default-route
  ## interface. IPv4 falls back to loopback, IPv6 to nothing.
  let probe =
    case addrFamily
    of AddressFamily.IPv4:
      Ipv4Probe
    of AddressFamily.IPv6:
      Ipv6Probe
    else:
      return @[]
  let ip =
    try:
      getPrimaryIPAddr(probe)
    except Exception as e:
      ## getPrimaryIPAddr has a bare Exception effect on Windows.
      debug "Could not retrieve the primary IP address",
        family = addrFamily, error = e.msg
      if addrFamily == AddressFamily.IPv6:
        return @[]
      Ipv4Loopback
  let prefix = if ip.family == IpAddressFamily.IPv4: 32 else: 128
  @[InterfaceAddress.init(initTAddress(ip, Port(0)), prefix)]

proc withWsTransport*(b: SwitchBuilder): SwitchBuilder =
  b.withTransport(
    proc(config: TransportConfig): Transport =
      WsTransport.new(config.upgr, rng = config.rng)
  )

proc getSecureKey(path: string): TLSPrivateKey {.raises: [Defect, IOError].} =
  trace "Key path is.", path = path
  let stringkey: string = readFile(path)
  try:
    let key = TLSPrivateKey.init(stringkey)
    return key
  except TLSStreamProtocolError as exc:
    debug "exception raised from getSecureKey", err = exc.msg

proc getSecureCert(path: string): TLSCertificate {.raises: [Defect, IOError].} =
  trace "Certificate path is.", path = path
  let stringCert: string = readFile(path)
  try:
    let cert = TLSCertificate.init(stringCert)
    return cert
  except TLSStreamProtocolError as exc:
    debug "exception raised from getSecureCert", err = exc.msg

proc withWssTransport*(
    b: SwitchBuilder, secureKeyPath: string, secureCertPath: string
): SwitchBuilder {.raises: [Defect, IOError].} =
  let key: TLSPrivateKey = getSecureKey(secureKeyPath)
  let cert: TLSCertificate = getSecureCert(secureCertPath)
  b.withWsTransport(
    tlsPrivateKey = key,
    tlsCertificate = cert,
    {TLSFlags.NoVerifyHost, TLSFlags.NoVerifyServerName}, # THIS IS INSECURE, NO?
  )

proc newWakuSwitch*(
    privKey = Opt.none(crypto.PrivateKey),
    address = MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet(),
    wsAddress = Opt.none(MultiAddress),
    quicAddress = Opt.none(MultiAddress),
    secureManagers: openarray[SecureProtocol] = [SecureProtocol.Noise],
    transportFlags: set[ServerFlags] = {},
    rng: crypto.Rng,
    inTimeout: Duration = 5.minutes,
    outTimeout: Duration = 5.minutes,
    maxConnections = MaxConnections,
    maxIn = -1,
    maxOut = -1,
    maxConnsPerPeer = MaxConnectionsPerPeer,
    nameResolver: NameResolver = nil,
    sendSignedPeerRecord = false,
    wssEnabled: bool = false,
    secureKeyPath: string = "",
    secureCertPath: string = "",
    agentString = Opt.none(string), # defaults to nim-libp2p version
    peerStoreCapacity = Opt.none(int), # defaults to 1.25 maxConnections
    rendezvous: RendezVous = nil,
    circuitRelay: Relay,
    natConfig = Opt.none(NATConfig),
): Switch {.raises: [Defect, IOError, LPError].} =
  var b = SwitchBuilder
    .new()
    .withRng(rng)
    .withMaxConnsPerPeer(maxConnsPerPeer)
    .withYamux()
    .withMplex(inTimeout, outTimeout)
    .withNoise()
    .withNameResolver(nameResolver)
    .withSignedPeerRecord(sendSignedPeerRecord)
    .withCircuitRelay(circuitRelay)
    .withAutonat()
    .withWildcardResolver(false)

  # UPnP and NAT-PMP port mapping via libp2p's NATService.
  # The extip strategy stays static in NetConfig.
  natConfig.withValue(config):
    b = b.withNAT(config)

  # libp2p 2.0.0 folded withMaxConnections and withMaxInOut into a single
  # `limits` field: they are mutually exclusive (last one wins), and
  # ConnectionLimits.maxInOut asserts maxIn/maxOut > 0. So apply explicit in/out
  # limits only when both are provided (>0); otherwise use the shared total cap.
  if maxIn > 0 and maxOut > 0:
    b = b.withMaxInOut(maxIn, maxOut)
  else:
    b = b.withMaxConnections(maxConnections)

  if peerStoreCapacity.isSome():
    b = b.withPeerStore(peerStoreCapacity.get())
  else:
    let defaultPeerStoreCapacity = int(maxConnections) * 5
    b = b.withPeerStore(defaultPeerStoreCapacity)
  if agentString.isSome():
    b = b.withAgentVersion(agentString.get())
  if privKey.isSome():
    b = b.withPrivateKey(privKey.get())
  # tcp always; ws/quic added when their addr is set
  var addresses: seq[MultiAddress]
  if wsAddress.isSome():
    addresses.add(wsAddress.get())
  addresses.add(address)
  if quicAddress.isSome():
    addresses.add(quicAddress.get())
  b = b.withAddresses(addresses)

  b = b.withTcpTransport(transportFlags)

  if wsAddress.isSome():
    if wssEnabled:
      b = b.withWssTransport(secureKeyPath, secureCertPath)
    else:
      b = b.withWsTransport()

  if quicAddress.isSome():
    b = b.withQuicTransport()

  if not rendezvous.isNil():
    b = b.withRendezVous()

  let switch = b.build()
  # The upstream wildcard service would announce every interface. This node
  # announces one primary address per family through the provider instead.
  switch.addressManager.networkInterfaceProvider = primaryInterfaceProvider
  DeliveryDialer.install(switch)
  switch
