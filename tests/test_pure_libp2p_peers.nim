{.used.}

import
  std/[sequtils, sets],
  testutils/unittests,
  chronos,
  libp2p/switch,
  libp2p/peerstore,
  libp2p/crypto/rng,
  libp2p/protocols/service_discovery,
  libp2p/protocols/service_discovery/types
import
  logos_delivery/waku/[waku_node, waku_core, node/peer_manager, waku_metadata],
  ./testlib/wakucore,
  ./testlib/wakunode

const ClusterId = 42.uint16

proc newPureLibp2pSwitch(): Switch =
  ## A bare nim-libp2p switch offering only kademlia service discovery: what a
  ## node hosting discovery through libp2p_module looks like from outside.
  let switch = newTestSwitch()
  switch.mount(
    ServiceDiscovery.new(switch, rng = newRng(), codec = ExtendedServiceDiscoveryCodec)
  )
  switch

proc newMemberNode(mountMeta = true): Future[WakuNode] {.async.} =
  let node = newTestWakuNode(generateSecp256k1Key(), clusterId = ClusterId)
  if mountMeta:
    discard node.mountMetadata(ClusterId, @[])
  await node.start()
  node

# identify, classification, and an asyncSpawned disconnect all have to land
const Settle = 1.seconds

proc connectExpectingDrop(peer: Switch, node: WakuNode) {.async.} =
  ## A rejected peer may be cut off while its own upgrade is still running, in
  ## which case its `connect` raises rather than returns. Either is a drop.
  try:
    await peer.connect(node.switch.peerInfo.peerId, node.switch.peerInfo.listenAddrs)
  except DialFailedError:
    discard

suite "Peer manager - pure-libp2p peers":
  asyncTest "budget off: a pure-libp2p peer is disconnected, as before":
    let node = await newMemberNode()
    let peer = newPureLibp2pSwitch()
    await peer.start()
    check node.peerManager.maxPureLibp2pPeers == 0

    await peer.connectExpectingDrop(node)
    await sleepAsync(Settle)

    check:
      not node.switch.isConnected(peer.peerInfo.peerId)
      not peer.isConnected(node.switch.peerInfo.peerId)
      node.peerManager.pureLibp2pPeers.len == 0

    await allFutures(node.stop(), peer.stop())

  asyncTest "budget on: an inbound pure-libp2p peer is kept and tracked":
    let node = await newMemberNode()
    node.peerManager.maxPureLibp2pPeers = 1
    let peer = newPureLibp2pSwitch()
    await peer.start()

    await peer.connect(node.switch.peerInfo.peerId, node.switch.peerInfo.listenAddrs)
    await sleepAsync(Settle)

    check:
      node.switch.isConnected(peer.peerInfo.peerId)
      peer.peerInfo.peerId in node.peerManager.pureLibp2pPeers
      # never offered to a waku protocol
      node.peerManager.switch.peerStore.peers(WakuMetadataCodec).allIt(
        it.peerId != peer.peerInfo.peerId
      )

    await allFutures(node.stop(), peer.stop())

  asyncTest "budget on: the N+1th inbound pure-libp2p peer is rejected":
    let node = await newMemberNode()
    node.peerManager.maxPureLibp2pPeers = 1
    let first = newPureLibp2pSwitch()
    let second = newPureLibp2pSwitch()
    await allFutures(first.start(), second.start())

    await first.connect(node.switch.peerInfo.peerId, node.switch.peerInfo.listenAddrs)
    await sleepAsync(Settle)
    await second.connectExpectingDrop(node)
    await sleepAsync(Settle)

    check:
      node.switch.isConnected(first.peerInfo.peerId)
      not node.switch.isConnected(second.peerInfo.peerId)
      node.peerManager.pureLibp2pPeers.len == 1

    await allFutures(node.stop(), first.stop(), second.stop())

  asyncTest "outbound pure-libp2p peers are exempt from the inbound budget":
    let node = await newMemberNode()
    node.peerManager.maxPureLibp2pPeers = 1
    let inboundPeer = newPureLibp2pSwitch()
    let dialed = newPureLibp2pSwitch()
    await allFutures(inboundPeer.start(), dialed.start())

    await inboundPeer.connect(
      node.switch.peerInfo.peerId, node.switch.peerInfo.listenAddrs
    )
    await sleepAsync(Settle)
    # budget is now full; our own dial must still be kept
    await node.connectToNodes(@[dialed.peerInfo.toRemotePeerInfo()])
    await sleepAsync(Settle)

    check:
      node.switch.isConnected(inboundPeer.peerInfo.peerId)
      node.switch.isConnected(dialed.peerInfo.peerId)
      node.peerManager.pureLibp2pPeers.len == 2

    await allFutures(node.stop(), inboundPeer.stop(), dialed.stop())

  asyncTest "a peer offering nothing we consume is rejected even with budget on":
    let node = await newMemberNode()
    node.peerManager.maxPureLibp2pPeers = 50
    let peer = newTestSwitch() # identify and ping only
    await peer.start()

    await peer.connectExpectingDrop(node)
    await sleepAsync(Settle)

    check:
      not node.switch.isConnected(peer.peerInfo.peerId)
      node.peerManager.pureLibp2pPeers.len == 0

    await allFutures(node.stop(), peer.stop())

  asyncTest "leaving clears the admission":
    let node = await newMemberNode()
    node.peerManager.maxPureLibp2pPeers = 1
    let peer = newPureLibp2pSwitch()
    await peer.start()

    await peer.connect(node.switch.peerInfo.peerId, node.switch.peerInfo.listenAddrs)
    await sleepAsync(Settle)
    check peer.peerInfo.peerId in node.peerManager.pureLibp2pPeers

    await peer.stop()
    await sleepAsync(Settle)
    check node.peerManager.pureLibp2pPeers.len == 0

    await node.stop()

  asyncTest "a node without metadata mounted still accepts everyone":
    let node = await newMemberNode(mountMeta = false)
    let peer = newTestSwitch()
    await peer.start()

    await peer.connect(node.switch.peerInfo.peerId, node.switch.peerInfo.listenAddrs)
    await sleepAsync(Settle)

    check:
      node.switch.isConnected(peer.peerInfo.peerId)
      node.peerManager.pureLibp2pPeers.len == 0

    await allFutures(node.stop(), peer.stop())
