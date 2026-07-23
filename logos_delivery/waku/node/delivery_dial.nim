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
  libp2p/muxers/muxer

export dialer

proc sortQuicFirst(addrs: seq[MultiAddress]): seq[MultiAddress] =
  addrs.filterIt("/quic-v1" in $it) & addrs.filterIt("/quic-v1" notin $it)

type DeliveryDial* = ref object of Dialer
  ## Logos Delivery dial policy layer. Replaces the switch dialer; every
  ## dial in the process goes through here. Dials quic addresses before tcp.

proc install*(T: typedesc[DeliveryDial], switch: Switch) =
  switch.dialer = DeliveryDial.new(
    switch.peerInfo.peerId, switch.connManager, switch.peerStore, switch.transports,
    switch.ms, switch.nameResolver,
  )

method connect*(
    self: DeliveryDial,
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
    self: DeliveryDial,
    peerId: PeerId,
    addrs: seq[MultiAddress],
    protos: seq[string],
    forceDial = false,
): Future[Stream] {.async: (raises: [DialFailedError, CancelledError]).} =
  await procCall Dialer(self).dial(peerId, sortQuicFirst(addrs), protos, forceDial)

method dialAndUpgrade*(
    self: DeliveryDial,
    peerId: Opt[PeerId],
    addrs: seq[MultiAddress],
    dir = Direction.Out,
): Future[Muxer] {.
    async: (raises: [CancelledError, MaError, TransportAddressError, LPError])
.} =
  await procCall Dialer(self).dialAndUpgrade(peerId, sortQuicFirst(addrs), dir)

method tryDial*(
    self: DeliveryDial, peerId: PeerId, addrs: seq[MultiAddress]
): Future[Opt[MultiAddress]] {.async: (raises: [DialFailedError, CancelledError]).} =
  await procCall Dialer(self).tryDial(peerId, sortQuicFirst(addrs))
