{.push raises: [].}

import chronicles, chronos, results, metrics

import
  libp2p/crypto/curve25519,
  libp2p/crypto/crypto,
  libp2p_mix,
  libp2p_mix/mix_node,
  libp2p_mix/mix_protocol,
  libp2p_mix/mix_metrics,
  libp2p_mix/delay_strategy,
  libp2p/[multiaddress, peerid],
  eth/common/keys

import
  logos_delivery/waku/node/peer_manager,
  logos_delivery/waku/waku_core,
  logos_delivery/waku/waku_enr,
  logos_delivery/waku/node/peer_manager/waku_peer_store

logScope:
  topics = "waku mix"

const MinMixPoolSize* = 4
  ## Smallest pool mix can build a path from. `PathLength` is 3, and under
  ## `exit_is_dest` the destination is itself a pool member that mix excludes
  ## from the path it picks, so three hops need a fourth entry to choose from.

type
  WakuMix* = ref object of MixProtocol
    peerManager*: PeerManager
    clusterId: uint16
    pubKey*: Curve25519Key

  WakuMixResult*[T] = Result[T, string]

  MixNodePubInfo* = object
    multiAddr*: string
    pubKey*: Curve25519Key

proc processBootNodes(
    bootnodes: seq[MixNodePubInfo], peermgr: PeerManager, mix: WakuMix
) =
  var count = 0
  for node in bootnodes:
    let pInfo = parsePeerInfo(node.multiAddr).valueOr:
      error "Failed to get peer id from multiaddress: ",
        error = error, multiAddr = $node.multiAddr
      continue
    let peerId = pInfo.peerId
    var peerPubKey: crypto.PublicKey
    if not peerId.extractPublicKey(peerPubKey):
      warn "Failed to extract public key from peerId, skipping node", peerId = peerId
      continue

    if peerPubKey.scheme != PKScheme.Secp256k1:
      warn "Peer public key is not Secp256k1, skipping node",
        peerId = peerId, scheme = peerPubKey.scheme
      continue

    let multiAddr = MultiAddress.init(node.multiAddr).valueOr:
      error "Failed to parse multiaddress", multiAddr = node.multiAddr, error = error
      continue

    ## `addPeer` before `nodePool.add`, not after: it writes the address book at
    ## default confidence, which would undo the `Infinite` confidence the pool
    ## sets to keep libp2p's hourly address pruning off our configured mix nodes.
    peermgr.addPeer(
      RemotePeerInfo.init(
        peerId, @[multiAddr], publicKey = peerPubKey, mixPubKey = Opt.some(node.pubKey)
      )
    )

    let mixPubInfo = MixPubInfo.init(peerId, multiAddr, node.pubKey, peerPubKey.skkey)
    mix.nodePool.add(mixPubInfo)
    count.inc()
  mix_pool_size.set(count)
  info "using mix bootstrap nodes ", count = count

proc new*(
    T: typedesc[WakuMix],
    nodeAddr: string,
    peermgr: PeerManager,
    clusterId: uint16,
    mixPrivKey: Curve25519Key,
    bootnodes: seq[MixNodePubInfo],
): WakuMixResult[T] =
  let mixPubKey = public(mixPrivKey)
  info "mixPubKey", mixPubKey = mixPubKey
  let nodeMultiAddr = MultiAddress.init(nodeAddr).valueOr:
    return err("failed to parse mix node address: " & $nodeAddr & ", error: " & error)
  let localMixNodeInfo = initMixNodeInfo(
    peermgr.switch.peerInfo.peerId, nodeMultiAddr, mixPubKey, mixPrivKey,
    peermgr.switch.peerInfo.publicKey.skkey, peermgr.switch.peerInfo.privateKey.skkey,
  )

  var m = WakuMix(peerManager: peermgr, clusterId: clusterId, pubKey: mixPubKey)
  procCall MixProtocol(m).init(
    localMixNodeInfo,
    peermgr.switch,
    delayStrategy = Opt.some(
      DelayStrategy(
        ExponentialDelayStrategy.new(meanDelay = 50'u16, rng = crypto.newRng())
      )
    ),
  )

  processBootNodes(bootnodes, peermgr, m)

  if m.nodePool.len < MinMixPoolSize:
    ## Not a warning: the pool is the peer store's mix book, so discovery
    ## (kademlia, rendezvous) keeps filling it after mount. Starting short of a
    ## full path is the normal boot state, not a misconfigured node.
    info "mix cannot publish yet, waiting for more mix nodes",
      poolSize = m.nodePool.len, required = MinMixPoolSize
  return ok(m)

proc poolSize*(mix: WakuMix): int =
  mix.nodePool.len

# Mix Protocol
