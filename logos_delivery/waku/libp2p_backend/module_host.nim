## `IHost` and `IStream` implementations backed by an external libp2p Logos
## module, reached through `ModuleTransport` (see `libp2p_iface/module_contract`).
##
## A stream is an opaque handle owned by the module; reads, writes and closes are
## requests on it. Connection queries answer from a snapshot that the host
## refreshes on every peer event and once a second.
{.push raises: [].}

import std/[tables, sequtils, strutils]
import chronos, chronicles, results
import libp2p/[errors, multiaddress, peerid]
import libp2p/stream/lpstream
import ../libp2p_iface/host
import ../libp2p_iface/stream
import ./module_transport

logScope:
  topics = "waku module host"

const ConnectionsRefreshInterval = chronos.seconds(1)

type
  ModuleStream* = ref object
    t: ModuleTransport
    handle: uint64
    peerId*: PeerId
    eof: bool

  StreamAcceptor = proc(
    stream: ModuleStream, codec: string
  ): Future[void].Raising([CancelledError]) {.gcsafe, raises: [].}

  ModuleHost* = ref object
    t: ModuleTransport
    identity: HostIdentityRes
    connectionsSnapshot: seq[HostConnection]
    peerHandlers: seq[tuple[kind: HostPeerEventKind, handler: HostPeerEventHandler]]
    acceptors: Table[string, StreamAcceptor]
    refreshLoop: Future[void]

# --- stream ------------------------------------------------------------------

proc raiseStreamError(reply: string) {.noreturn, raises: [LPStreamError].} =
  if reply.startsWith(ErrStreamMaxSize):
    raise newException(MaxSizeError, reply[ErrStreamMaxSize.len .. ^1])
  if reply.startsWith(ErrStreamRemoteClosed):
    raise
      newException(LPStreamRemoteClosedError, reply[ErrStreamRemoteClosed.len .. ^1])
  raise newException(LPStreamError, reply)

proc writeLP*(
    s: ModuleStream, data: seq[byte]
): Future[void] {.async: (raises: [CancelledError, LPStreamError]).} =
  (
    await s.t.call(
      ReqStreamWriteLp, StreamWriteReq(handle: s.handle, data: data), Empty
    )
  ).isOkOr:
    raiseStreamError(error)

proc readLp*(
    s: ModuleStream, maxSize: int
): Future[seq[byte]] {.async: (raises: [CancelledError, LPStreamError]).} =
  let res = (
    await s.t.call(
      ReqStreamReadLp,
      StreamReadReq(handle: s.handle, maxSize: int64(maxSize)),
      StreamReadRes,
    )
  ).valueOr:
    if error.startsWith(ErrStreamRemoteClosed):
      s.eof = true
    raiseStreamError(error)
  return res.data

proc close*(s: ModuleStream): Future[void] {.async: (raises: [CancelledError]).} =
  s.eof = true
  (await s.t.call(ReqStreamClose, StreamReq(handle: s.handle), Empty)).isOkOr:
    debug "failed to close the module stream", error = error

proc closeWithEof*(
    s: ModuleStream
): Future[void] {.async: (raises: [CancelledError]).} =
  s.eof = true
  (await s.t.call(ReqStreamCloseWithEof, StreamReq(handle: s.handle), Empty)).isOkOr:
    debug "failed to close the module stream", error = error

proc atEof*(s: ModuleStream): bool =
  return s.eof

# --- host --------------------------------------------------------------------

proc parsePeerId(text: string): PeerId =
  return PeerId.init(text).valueOr:
    default(PeerId)

proc parseAddrs(addrs: seq[string]): seq[MultiAddress] =
  return addrs.mapIt(MultiAddress.init(it)).filterIt(it.isOk()).mapIt(it.get())

proc refreshConnections(h: ModuleHost) {.async: (raises: [CancelledError]).} =
  let res = (await h.t.call(ReqHostConnections, Empty(), ConnectionsRes)).valueOr:
    debug "failed to refresh the connections", error = error
    return
  h.connectionsSnapshot = res.connections.mapIt(
    HostConnection(
      peerId: parsePeerId(it.peerId),
      inbound: it.inbound,
      observedAddr:
        if it.observedAddr.len > 0:
          MultiAddress.init(it.observedAddr).toOpt()
        else:
          Opt.none(MultiAddress),
      streams: it.streams.mapIt(HostStream(protocol: it.protocol, inbound: it.inbound)),
    )
  )

proc runRefresh(h: ModuleHost) {.async: (raises: []).} =
  while true:
    try:
      await sleepAsync(ConnectionsRefreshInterval)
      await h.refreshConnections()
    except CancelledError:
      return

proc onStream(h: ModuleHost, payload: seq[byte]) =
  let ev = cborDecode(payload, HostStreamEv).valueOr:
    debug "invalid host stream event", error = error
    return
  let accept = h.acceptors.getOrDefault(ev.codec)
  if accept.isNil():
    debug "no handler for the inbound stream", codec = ev.codec
    return
  let stream = ModuleStream(t: h.t, handle: ev.handle, peerId: parsePeerId(ev.peerId))
  asyncSpawn accept(stream, ev.codec)

proc onPeer(h: ModuleHost, payload: seq[byte]) =
  let ev = cborDecode(payload, HostPeerEv).valueOr:
    debug "invalid host peer event", error = error
    return
  let kind =
    case ev.kind
    of 0: HostPeerEventKind.Joined
    of 1: HostPeerEventKind.Left
    else: HostPeerEventKind.Identified
  let event = HostPeerEvent(kind: kind, initiator: ev.initiator)
  for registered in h.peerHandlers:
    if registered.kind == kind:
      asyncSpawn registered.handler(parsePeerId(ev.peerId), event)

proc new*(T: type ModuleHost, transport: ModuleTransport): ModuleHost =
  let h = ModuleHost(t: transport)
  let streamHook = proc(payload: seq[byte]) {.gcsafe, raises: [].} =
    h.onStream(payload)
  let peerHook = proc(payload: seq[byte]) {.gcsafe, raises: [].} =
    h.onPeer(payload)
  transport.subscribe(EvHostStream, streamHook)
  transport.subscribe(EvHostPeer, peerHook)
  return h

proc fetchIdentity(h: ModuleHost) {.async: (raises: [CancelledError]).} =
  h.identity = (await h.t.call(ReqHostIdentity, Empty(), HostIdentityRes)).valueOr:
    error "failed to get the libp2p module identity", error = error
    return

proc start*(
    h: ModuleHost
): Future[void] {.async: (raises: [CancelledError, LPError]).} =
  (await h.t.call(ReqHostStart, Empty(), Empty)).isOkOr:
    raise newException(LPError, "libp2p module host start failed: " & error)
  await h.fetchIdentity()
  await h.refreshConnections()
  if h.refreshLoop.isNil():
    h.refreshLoop = h.runRefresh()

proc stop*(h: ModuleHost): Future[void] {.async: (raises: [CancelledError]).} =
  if not h.refreshLoop.isNil():
    await h.refreshLoop.cancelAndWait()
    h.refreshLoop = nil
  (await h.t.call(ReqHostStop, Empty(), Empty)).isOkOr:
    warn "failed to stop the libp2p module host", error = error

proc peerId*(h: ModuleHost): PeerId =
  return parsePeerId(h.identity.peerId)

proc listenAddrs*(h: ModuleHost): seq[MultiAddress] =
  return parseAddrs(h.identity.listenAddrs)

proc announcedAddrs*(h: ModuleHost): seq[MultiAddress] =
  return parseAddrs(h.identity.announcedAddrs)

proc disconnect*(
    h: ModuleHost, peerId: PeerId
): Future[void] {.async: (raises: [CancelledError]).} =
  (await h.t.call(ReqHostDisconnect, PeerReq(peerId: $peerId), Empty)).isOkOr:
    debug "failed to disconnect from the peer", error = error

proc connections*(h: ModuleHost): seq[HostConnection] =
  return h.connectionsSnapshot

proc isConnected*(h: ModuleHost, peerId: PeerId): bool =
  return h.connectionsSnapshot.anyIt(it.peerId == peerId)

proc addPeerEventHandler*(
    h: ModuleHost, handler: HostPeerEventHandler, kind: HostPeerEventKind
) =
  h.peerHandlers.add((kind: kind, handler: handler))

proc dial*(
    h: ModuleHost, peerId: PeerId, addrs: seq[MultiAddress], codec: string
): Future[ModuleStream] {.async: (raises: [CancelledError, LPError]).} =
  let res = (
    await h.t.call(
      ReqHostDial,
      DialReq(peerId: $peerId, addrs: addrs.mapIt($it), codec: codec),
      DialRes,
    )
  ).valueOr:
    raise newException(LPError, "dial failed: " & error)
  return ModuleStream(t: h.t, handle: res.handle, peerId: peerId)

proc mountHandler*[P](h: ModuleHost, codec: string, proto: P) {.raises: [LPError].} =
  ## Mounts `proto` on `codec`: its `handleStream` serves every incoming stream.
  mixin handleStream
  h.acceptors[codec] = proc(
      stream: ModuleStream, name: string
  ): Future[void] {.async: (raises: [CancelledError]).} =
    await proto.handleStream(stream, name)
  # the module is told about the codec when the host starts; a running host is told now
  asyncSpawn (
    proc(): Future[void] {.async: (raises: []).} =
      try:
        (await h.t.call(ReqHostMount, MountReq(codec: codec), Empty)).isOkOr:
          error "failed to mount the codec in the libp2p module", error = error
      except CancelledError:
        discard
  )()

static:
  doAssert ModuleHost is IHost
  doAssert ModuleStream is IStream
