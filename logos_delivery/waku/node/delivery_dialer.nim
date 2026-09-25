{.push raises: [].}

import std/[sequtils, strutils]
import chronos, results
import
  libp2p/dial,
  libp2p/dialer,
  libp2p/switch,
  libp2p/peerid,
  libp2p/multiaddress,
  libp2p/stream/connection,
  libp2p/muxers/muxer,
  libp2p/transports/transport,
  libp2p/transports/quictransport

export dialer

const QuicDialTimeout* = 3.seconds
  ## Budget for an outgoing quic handshake before libp2p moves on to the next
  ## address. An unreachable quic address otherwise stalls for lsquic's 10s
  ## handshake timeout, which is the peer manager's whole dial budget.

proc isQuic(ma: MultiAddress): bool =
  "/quic-v1" in $ma

proc sortQuicFirst(addrs: seq[MultiAddress]): seq[MultiAddress] =
  ## Keeps a single quic address when there is something to fall back to, so a
  ## peer listing several dead quic addresses costs one QuicDialTimeout.
  let quicAddrs = addrs.filterIt(it.isQuic())
  let otherAddrs = addrs.filterIt(not it.isQuic())
  if quicAddrs.len > 0 and otherAddrs.len > 0:
    return quicAddrs[0 .. 0] & otherAddrs
  return quicAddrs & otherAddrs

type QuicDialBudget = ref object of Transport
  ## The dialer's view of the quic transport: bounds the outgoing handshake
  ## only. Identify and metadata then run on an established connection, outside
  ## the budget. The switch keeps the unwrapped transport for listening.
  quic: Transport

method handles*(
    self: QuicDialBudget, address: MultiAddress
): bool {.gcsafe, raises: [].} =
  self.quic.handles(address)

method dial*(
    self: QuicDialBudget,
    hostname: string,
    address: MultiAddress,
    peerId: Opt[PeerId] = Opt.none(PeerId),
    dir: Direction = Direction.Out,
): Future[RawConn] {.async: (raises: [transport.TransportError, CancelledError]).} =
  # An inbound-direction dial is DCUtR's hole punch, which loops until DCUtR
  # cancels it.
  if dir != Direction.Out:
    return await self.quic.dial(hostname, address, peerId, dir)
  try:
    return await self.quic.dial(hostname, address, peerId, dir).wait(QuicDialTimeout)
  except AsyncTimeoutError as e:
    raise newException(
      TransportDialError, "quic dial timed out after " & $QuicDialTimeout, e
    )

method upgrade*(
    self: QuicDialBudget, conn: RawConn, peerId: Opt[PeerId]
): Future[Muxer] {.async: (raises: [CancelledError, LPError], raw: true).} =
  self.quic.upgrade(conn, peerId)

type DeliveryDialer* = ref object of Dialer
  ## Logos Delivery dial policy layer. Replaces the switch dialer, so connect
  ## and dial go through here. Dials quic addresses before tcp, and bounds the
  ## quic handshake so tcp is still tried when quic does not answer.

proc install*(T: typedesc[DeliveryDialer], switch: Switch) =
  let transports = switch.transports.mapIt(
    if it of QuicTransport:
      Transport(QuicDialBudget(quic: it))
    else:
      it
  )
  switch.dialer = DeliveryDialer.new(
    switch.peerInfo.peerId, switch.connManager, switch.peerStore, transports, switch.ms,
    switch.nameResolver,
  )

method connect*(
    self: DeliveryDialer,
    peerId: PeerId,
    addrs: seq[MultiAddress],
    forceDial = false,
    reuseConnection = true,
    dir = Direction.Out,
) {.async: (raises: [DialFailedError, CancelledError]).} =
  await procCall Dialer(self).connect(
    peerId, sortQuicFirst(addrs), forceDial, reuseConnection, dir
  )

method dial*(
    self: DeliveryDialer,
    peerId: PeerId,
    addrs: seq[MultiAddress],
    protos: seq[string],
    forceDial = false,
): Future[Stream] {.async: (raises: [DialFailedError, CancelledError]).} =
  await procCall Dialer(self).dial(peerId, sortQuicFirst(addrs), protos, forceDial)

method dialAndUpgrade*(
    self: DeliveryDialer,
    peerId: Opt[PeerId],
    addrs: seq[MultiAddress],
    dir = Direction.Out,
): Future[Muxer] {.
    async: (raises: [CancelledError, MaError, TransportAddressError, LPError])
.} =
  await procCall Dialer(self).dialAndUpgrade(peerId, sortQuicFirst(addrs), dir)

method tryDial*(
    self: DeliveryDialer, peerId: PeerId, addrs: seq[MultiAddress]
): Future[Opt[MultiAddress]] {.async: (raises: [DialFailedError, CancelledError]).} =
  await procCall Dialer(self).tryDial(peerId, sortQuicFirst(addrs))
