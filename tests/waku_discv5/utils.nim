import results, chronos, libp2p/crypto/crypto as libp2p_keys, eth/keys as eth_keys

import
  logos_delivery/waku/
    [waku_core/topics, waku_enr, discovery/waku_discv5, node/peer_manager/peer_manager],
  ../testlib/[common, wakucore]

proc newTestDiscv5*(
    privKey: libp2p_keys.PrivateKey,
    bindIp: string,
    tcpPort: uint16,
    udpPort: uint16,
    record: waku_enr.Record,
    bootstrapRecords = newSeq[waku_enr.Record](),
    queue = newAsyncEventQueue[SubscriptionEvent](30),
    peerManager: Opt[PeerManager] = Opt.none(PeerManager),
): WakuDiscoveryV5 =
  let config = WakuDiscoveryV5Config(
    privateKey: eth_keys.PrivateKey(privKey.skkey),
    address: parseIpAddress(bindIp),
    port: Port(udpPort),
    bootstrapRecords: bootstrapRecords,
  )

  let discv5 = WakuDiscoveryV5.new(
    rng = rng(),
    conf = config,
    record = Opt.some(record),
    queue = queue,
    peerManager = peerManager,
  )

  return discv5
