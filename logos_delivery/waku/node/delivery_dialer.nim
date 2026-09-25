{.push raises: [].}

import std/[sequtils, strutils]
import chronos, chronicles, results
import
  libp2p/dial,
  libp2p/dialer,
  libp2p/switch,
  libp2p/peerid,
  libp2p/multiaddress,
  libp2p/stream/connection,
  libp2p/muxers/muxer

export dialer

logScope:
  topics = "waku dialer"

const QuicDialTimeout* = 3.seconds
  ## Budget for the quic attempt before falling back to the other addresses.
  ## An unreachable quic address stalls for lsquic's 10s handshake timeout,
  ## which would otherwise consume the whole dial budget.

proc isQuic(ma: MultiAddress): bool =
  "/quic-v1" in $ma

proc sortQuicFirst(addrs: seq[MultiAddress]): seq[MultiAddress] =
  addrs.filterIt(it.isQuic()) & addrs.filterIt(not it.isQuic())

type DeliveryDialer* = ref object of Dialer
  ## Logos Delivery dial policy layer. Replaces the switch dialer; every
  ## dial in the process goes through here. Dials quic addresses before tcp,
  ## and falls back to tcp when quic does not connect within QuicDialTimeout.

proc install*(T: typedesc[DeliveryDialer], switch: Switch) =
  switch.dialer = DeliveryDialer.new(
    switch.peerInfo.peerId, switch.connManager, switch.peerStore, switch.transports,
    switch.ms, switch.nameResolver,
  )

method connect*(
    self: DeliveryDialer,
    peerId: PeerId,
    addrs: seq[MultiAddress],
    forceDial = false,
    reuseConnection = true,
    dir = Direction.Out,
) {.async: (raises: [DialFailedError, CancelledError]).} =
  let quicAddrs = addrs.filterIt(it.isQuic())
  let otherAddrs = addrs.filterIt(not it.isQuic())
  if quicAddrs.len == 0 or otherAddrs.len == 0:
    await procCall Dialer(self).connect(peerId, addrs, forceDial, reuseConnection, dir)
    return

  try:
    await procCall Dialer(self)
      .connect(peerId, quicAddrs, forceDial, reuseConnection, dir)
      .wait(QuicDialTimeout)
    return
  except AsyncTimeoutError:
    debug "quic dial timed out, falling back", peerId, quicAddrs
  except DialFailedError as e:
    debug "quic dial failed, falling back", peerId, quicAddrs, error = e.msg

  await procCall Dialer(self).connect(
    peerId, otherAddrs, forceDial, reuseConnection, dir
  )

method dial*(
    self: DeliveryDialer,
    peerId: PeerId,
    addrs: seq[MultiAddress],
    protos: seq[string],
    forceDial = false,
): Future[Stream] {.async: (raises: [DialFailedError, CancelledError]).} =
  # connect first so the stream dial goes through the quic fallback above
  await self.connect(peerId, addrs, forceDial)
  await procCall Dialer(self).dial(peerId, protos)

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
