## Owned host interface: connectivity services logos-delivery needs from a
## libp2p stack (identity, listening, dialing, protocol registration, peer
## events). See `stream.nim` for the streams a host hands out.
{.push raises: [].}

import chronos, results
import libp2p/[peerid, multiaddress]
import ./stream

export peerid, multiaddress, stream

type
  HostPeerEventKind* {.pure.} = enum
    Joined ## a connection to the peer was established
    Left ## the last connection to the peer closed
    Identified ## the peer finished the identify exchange

  HostPeerEvent* = object
    kind*: HostPeerEventKind
    initiator*: bool ## we dialed the peer (Joined only)

  HostPeerEventHandler* = proc(peerId: PeerId, event: HostPeerEvent): Future[void] {.
    async: (raises: [CancelledError]), gcsafe
  .}

  HostStream* = object
    protocol*: string
    inbound*: bool

  HostConnection* = object
    peerId*: PeerId
    inbound*: bool
    observedAddr*: Opt[MultiAddress]
    streams*: seq[HostStream] ## the logical streams open on the connection

type IHost* = concept h
  # Contract a host backend must satisfy; a backend is any type for which these
  # calls compile.
  h.peerId() is PeerId
  h.listenAddrs() is seq[MultiAddress]
  h.announcedAddrs() is seq[MultiAddress]
  h.start() is Future[void]
  h.stop() is Future[void]
  h.disconnect(PeerId) is Future[void]
  h.connections() is seq[HostConnection]
  h.addPeerEventHandler(HostPeerEventHandler, HostPeerEventKind)
  h.isConnected(PeerId) is bool
