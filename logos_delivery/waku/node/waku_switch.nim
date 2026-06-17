# Waku Switch utils.
{.push raises: [].}

import
  std/options,
  chronos,
  chronicles,
  eth/keys,
  libp2p/crypto/crypto,
  libp2p/protocols/pubsub/gossipsub,
  libp2p/protocols/rendezvous,
  libp2p/protocols/connectivity/relay/relay,
  libp2p/nameresolving/nameresolver,
  libp2p/builders,
  libp2p/switch,
  libp2p/transports/[transport, tcptransport, wstransport]

# override nim-libp2p default value (which is also 1)
const MaxConnectionsPerPeer* = 1

const MaxConnections* = 50

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
    info "exception raised from getSecureKey", err = exc.msg

proc getSecureCert(path: string): TLSCertificate {.raises: [Defect, IOError].} =
  trace "Certificate path is.", path = path
  let stringCert: string = readFile(path)
  try:
    let cert = TLSCertificate.init(stringCert)
    return cert
  except TLSStreamProtocolError as exc:
    info "exception raised from getSecureCert", err = exc.msg

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
    privKey = none(crypto.PrivateKey),
    address = MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet(),
    wsAddress = none(MultiAddress),
    quicAddress = none(MultiAddress),
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
    agentString = none(string), # defaults to nim-libp2p version
    peerStoreCapacity = none(int), # defaults to 1.25 maxConnections
    rendezvous: RendezVous = nil,
    circuitRelay: Relay,
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

  b.build()
