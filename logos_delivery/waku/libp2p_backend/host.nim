## nim-libp2p `Switch` implementation of the `IHost` interface.
##
## Streams handed out by this host are nim-libp2p `Connection`s, which satisfy
## `IStream` as they are.
{.push raises: [].}

import
  std/tables,
  results,
  chronos,
  libp2p/[switch, peerinfo, connmanager, errors, peerstore],
  libp2p/protocols/protocol,
  libp2p/stream/connection,
  libp2p/stream/lpstream,
  libp2p/muxers/muxer
import ../libp2p_iface/host except Stream
import ../libp2p_iface/stream

export host

type Libp2pHost* = ref object
  switch*: Switch

proc new*(T: type Libp2pHost, switch: Switch): Libp2pHost =
  return Libp2pHost(switch: switch)

type Libp2pStream* = Connection ## A stream opened through this host.

proc peerId*(h: Libp2pHost): PeerId =
  return h.switch.peerInfo.peerId

proc peerStore*(h: Libp2pHost): PeerStore =
  ## The peer book; backend specific for now.
  return h.switch.peerStore

proc listenAddrs*(h: Libp2pHost): seq[MultiAddress] =
  return h.switch.peerInfo.listenAddrs

proc announcedAddrs*(h: Libp2pHost): seq[MultiAddress] =
  return h.switch.peerInfo.addrs

proc start*(
    h: Libp2pHost
): Future[void] {.async: (raises: [CancelledError, LPError]).} =
  await h.switch.start()

proc stop*(h: Libp2pHost): Future[void] {.async: (raises: [CancelledError]).} =
  await h.switch.stop()

proc disconnect*(
    h: Libp2pHost, peerId: PeerId
): Future[void] {.async: (raises: [CancelledError]).} =
  await h.switch.disconnect(peerId)

proc isConnected*(h: Libp2pHost, peerId: PeerId): bool =
  return h.switch.isConnected(peerId)

proc connections*(h: Libp2pHost): seq[HostConnection] =
  var conns: seq[HostConnection]
  for peerId, muxers in h.switch.connManager.getConnections():
    for muxer in muxers:
      var streams: seq[HostStream]
      for stream in muxer.getStreams():
        streams.add(
          HostStream(protocol: stream.protocol, inbound: stream.dir == Direction.In)
        )
      conns.add(
        HostConnection(
          peerId: peerId,
          inbound: muxer.connection.transportDir == Direction.In,
          observedAddr: muxer.connection.observedAddr,
          streams: streams,
        )
      )
  return conns

proc findOpenStream*(
    h: Libp2pHost, peerId: PeerId, protocol: string
): Result[Opt[Connection], string] =
  ## The first open stream of the peer on `protocol`, if any. Errors when the
  ## peer has no connection at all.
  let peerIdsMuxers = h.switch.connManager.getConnections()
  if not peerIdsMuxers.contains(peerId):
    return err("peerId not found in connManager: " & $peerId)

  for muxer in peerIdsMuxers.getOrDefault(peerId):
    for stream in muxer.getStreams():
      if stream.protocol == protocol and not LPStream(stream).isClosed and
          not LPStream(stream).isClosedRemotely:
        return ok(Opt.some(stream))
  return ok(Opt.none(Connection))

proc connect*(
    h: Libp2pHost, peerId: PeerId, addrs: seq[MultiAddress]
): Future[void] {.async: (raises: [DialFailedError, CancelledError]).} =
  await h.switch.connect(peerId, addrs)

proc toSwitchHandler(
    handler: HostPeerEventHandler, kind: HostPeerEventKind
): PeerEventHandler =
  return proc(peerId: PeerId, event: PeerEvent) {.async: (raises: [CancelledError]).} =
    # `initiator` only exists on Joined events
    let initiator = event.kind == PeerEventKind.Joined and event.initiator
    await handler(peerId, HostPeerEvent(kind: kind, initiator: initiator))

proc addPeerEventHandler*(
    h: Libp2pHost, handler: HostPeerEventHandler, kind: HostPeerEventKind
) =
  ## Calls handler on every peer event of the given kind.
  let switchKind =
    case kind
    of HostPeerEventKind.Joined: PeerEventKind.Joined
    of HostPeerEventKind.Left: PeerEventKind.Left
    of HostPeerEventKind.Identified: PeerEventKind.Identified
  h.switch.addPeerEventHandler(handler.toSwitchHandler(kind), switchKind)

proc mount*(
    h: Libp2pHost, codec: string, handler: LPProtoHandler, matcher: Matcher = nil
) {.raises: [LPError].} =
  ## Registers a handler for the streams opened on `codec`.
  let proto = LPProtocol()
  proto.codec = codec
  proto.handler = handler
  # a running switch only accepts protocols that are started, and this one has nothing to start
  proto.started = true
  h.switch.mount(proto, matcher)

proc mountHandler*[P](
    h: Libp2pHost, codec: string, proto: P, matcher: Matcher = nil
) {.raises: [LPError].} =
  ## Mounts `proto` on `codec`: its `handleStream` serves every incoming stream.
  mixin handleStream
  let handler = proc(
      stream: Connection, name: string
  ) {.async: (raises: [CancelledError]).} =
    await proto.handleStream(stream, name)

  h.mount(codec, handler, matcher)

proc dial*(
    h: Libp2pHost, peerId: PeerId, addrs: seq[MultiAddress], codec: string
): Future[Connection] {.async: (raises: [DialFailedError, CancelledError]).} =
  return await h.switch.dial(peerId, addrs, codec)

proc dial*(
    h: Libp2pHost, peerId: PeerId, codec: string
): Future[Connection] {.async: (raises: [DialFailedError, CancelledError]).} =
  return await h.switch.dial(peerId, codec)

static:
  doAssert Libp2pHost is IHost
  doAssert Connection is IStream
