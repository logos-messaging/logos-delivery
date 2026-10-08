{.used.}

## Mix test fixtures.

import
  chronos,
  results,
  libp2p/[multiaddress, peerid, peerinfo, switch],
  libp2p/crypto/crypto,
  libp2p_mix/[curve25519, mix_protocol]
import
  logos_delivery/waku/[waku_core, waku_node, waku_mix],
  logos_delivery/waku/node/peer_manager,
  logos_delivery/waku/node/peer_manager/waku_peer_store,
  logos_delivery/waku/discovery/[peer_discovery_interface, peer_discovery_conversion],
  ./[wakucore, wakunode]

proc mountMixWith(
    node: WakuNode,
    addressPolicy: PeerAddressPolicy,
    bootnodes: seq[MixNodePubInfo] = @[],
) {.async.} =
  let keys = generateKeyPair().expect("mix key pair")
  (await node.mountMix(DefaultClusterId, keys.privateKey, bootnodes, addressPolicy)).isOkOr:
    raiseAssert "mountMix: " & $error

proc mixNode*(
    addressPolicy: PeerAddressPolicy = mixAddressPolicy(false),
    bootnodes: seq[MixNodePubInfo] = @[],
): Future[WakuNode] {.async.} =
  ## A node with mix that never starts, so it dials nothing.
  let node = newTestWakuNode(generateSecp256k1Key(), quicEnabled = false)
  await node.mountMixWith(addressPolicy, bootnodes)
  return node

proc discover*(
    node: WakuNode,
    addrs: seq[string],
    peerId = PeerId.init(generateSecp256k1Key()).tryGet(),
): PeerId {.discardable.} =
  ## Stores a discovery record with a new mix key, for a new or known peer.
  let keys = generateKeyPair().expect("mix key pair")
  let found = DiscoveredPeer(
    peerId: $peerId,
    addrs: addrs,
    services: @[DiscoveredService(id: MixProtocolID, data: @(keys.publicKey))],
  )
  node.peerManager.addPeer(found.toRemotePeerInfo().expect("discovered peer"))
  return peerId

proc bootnode*(address: string): MixNodePubInfo =
  let peerId = PeerId.init(generateSecp256k1Key()).tryGet()
  let keys = generateKeyPair().expect("mix key pair")
  MixNodePubInfo(multiAddr: address & "/p2p/" & $peerId, pubKey: keys.publicKey)

proc inPool*(node: WakuNode, peerId: PeerId): bool =
  node.wakuMix.nodePool.get(peerId).isSome()

proc hopOf*(node: WakuNode, peerId: PeerId): MultiAddress =
  node.wakuMix.nodePool.get(peerId).expect("pool entry").multiAddr
