{.used.}

import
  testutils/unittests,
  chronos,
  libp2p/switch,
  libp2p/protocols/protocol,
  libp2p/crypto/rng,
  libp2p/protocols/service_discovery,
  libp2p/protocols/service_discovery/types,
  libp2p_mix/mix_protocol
import
  logos_delivery/waku/[waku_node, waku_core, node/peer_manager, waku_metadata],
  ./testlib/testasync,
  ./testlib/wakucore,
  ./testlib/wakunode

const ClusterId = 42.uint16

# identify, the metadata exchange and an asyncSpawned disconnect all have to land
const Soak = 3.seconds

proc newServiceDiscoverySwitch(): Switch =
  ## A bare nim-libp2p switch offering only kademlia service discovery: what a
  ## node hosting discovery through libp2p_module looks like from outside.
  let switch = newTestSwitch()
  switch.mount(
    ServiceDiscovery.new(switch, rng = newRng(), codec = ExtendedServiceDiscoveryCodec)
  )
  switch

proc newMixSwitch(): Switch =
  let switch = newTestSwitch()
  let mix = LPProtocol(codecs: @[MixProtocolID])
  mix.handler = proc(
      stream: Stream, proto: string
  ) {.async: (raises: [CancelledError]).} =
    await stream.close()
  switch.mount(mix)
  switch

proc newMetadataNode(
    clusterId = ClusterId, mountMeta = true
): Future[WakuNode] {.async.} =
  let node = newTestWakuNode(generateSecp256k1Key(), clusterId = clusterId)
  if mountMeta:
    discard node.mountMetadata(clusterId, @[])
  await node.start()
  node

proc countDisconnects(node: WakuNode): ref int =
  let count = new int
  proc onLeft(peerId: PeerId, event: PeerEvent) {.async: (raises: [CancelledError]).} =
    count[].inc()

  node.switch.addPeerEventHandler(onLeft, PeerEventKind.Left)
  count

proc staysConnected(node: WakuNode, peer: Switch): Future[bool] {.async.} =
  ## Connects `peer` to `node` and reports whether both sides still hold the
  ## connection, with no disconnect seen, once the soak is over.
  let disconnects = node.countDisconnects()
  await peer.connect(node.switch.peerInfo.peerId, node.switch.peerInfo.listenAddrs)
  await sleepAsync(Soak)
  return
    disconnects[] == 0 and node.switch.isConnected(peer.peerInfo.peerId) and
    peer.isConnected(node.switch.peerInfo.peerId)

suite "Peer manager - peers without waku metadata":
  asyncTest "a service-discovery-only peer stays connected":
    let node = await newMetadataNode()
    let peer = newServiceDiscoverySwitch()
    await peer.start()
    defer:
      await allFutures(node.stop(), peer.stop())

    check:
      await node.staysConnected(peer)
      WakuMetadataCodec notin node.switch.peerStore[ProtoBook][peer.peerInfo.peerId]

  asyncTest "a mix-only peer stays connected":
    let node = await newMetadataNode()
    let peer = newMixSwitch()
    await peer.start()
    defer:
      await allFutures(node.stop(), peer.stop())

    check await node.staysConnected(peer)

  asyncTest "a peer offering no application protocol is not disconnected by us":
    let node = await newMetadataNode()
    let peer = newTestSwitch() # identify and ping only
    await peer.start()
    defer:
      await allFutures(node.stop(), peer.stop())

    check await node.staysConnected(peer)

  asyncTest "a node without metadata mounted still accepts everyone":
    let node = await newMetadataNode(mountMeta = false)
    let peer = newTestSwitch()
    await peer.start()
    defer:
      await allFutures(node.stop(), peer.stop())

    check await node.staysConnected(peer)

suite "Peer manager - peers with waku metadata":
  asyncTest "a peer of the same cluster stays connected":
    let node = await newMetadataNode()
    let peer = await newMetadataNode()
    defer:
      await allFutures(node.stop(), peer.stop())

    check await node.staysConnected(peer.switch)

  asyncTest "a peer of another cluster is disconnected":
    let node = await newMetadataNode()
    let peer = await newMetadataNode(clusterId = ClusterId + 1)
    defer:
      await allFutures(node.stop(), peer.stop())

    try:
      await peer.switch.connect(
        node.switch.peerInfo.peerId, node.switch.peerInfo.listenAddrs
      )
    except DialFailedError:
      discard # cut off while its own upgrade was still running
    checkUntilTimeout:
      not node.switch.isConnected(peer.switch.peerInfo.peerId)
