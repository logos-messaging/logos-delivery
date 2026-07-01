{.used.}

import
  std/[options, net],
  results,
  testutils/unittests,
  chronos,
  libp2p/switch,
  libp2p/peerId,
  libp2p/crypto/crypto,
  eth/keys,
  eth/p2p/discoveryv5/enr

import
  logos_delivery/waku/[
    waku_node,
    discovery/waku_discv5,
    net/auto_port,
    waku_peer_exchange,
    waku_peer_exchange/rpc,
    waku_peer_exchange/protocol,
    waku_peer_exchange/client,
    node/peer_manager,
    waku_core,
  ],
  ../testlib/[futures, wakucore, assertions]

proc startDiscv5WithAutoPort*(
    node: WakuNode,
    key: keys.PrivateKey,
    bindIp: IpAddress,
    bootstrapRecords: seq[enr.Record] = @[],
): Future[Result[WakuDiscoveryV5, string]] {.async.} =
  proc attempt(
      p: Port
  ): Future[Result[WakuDiscoveryV5, string]] {.async: (raises: []).} =
    var record = node.enr
    record.update(key, udpPort = Opt.some(p)).isOkOr:
      return err("could not set discv5 udp port in enr: " & $error)
    let conf = WakuDiscoveryV5Config(
      discv5Config: none(DiscoveryConfig),
      address: bindIp,
      port: p,
      privateKey: key,
      bootstrapRecords: bootstrapRecords,
      autoupdateRecord: true,
    )
    let wd = WakuDiscoveryV5.new(node.rng, conf, some(record), some(node.peerManager))
    (await wd.start()).isOkOr:
      return err(error)
    return ok(wd)

  return await tryWithAutoPort[WakuDiscoveryV5](Port(0), attempt)

proc dialForPeerExchange*(
    client: WakuNode,
    peerInfo: RemotePeerInfo,
    requestedPeers: uint64 = 1,
    minimumPeers: uint64 = 0,
    attempts: uint64 = 100,
): Future[Result[WakuPeerExchangeResult[PeerExchangeResponse], string]] {.async.} =
  # Dials a peer and awaits until it's able to receive a peer exchange response
  # For the test, the relevant part is the dialPeer call. 
  # But because the test needs peers, and due to the asynchronous nature of the dialing,
  # we await until we receive peers from the peer exchange protocol.
  var attempts = attempts

  while attempts > 0:
    let connOpt = await client.peerManager.dialPeer(peerInfo, WakuPeerExchangeCodec)
    require connOpt.isSome()
    await sleepAsync(FUTURE_TIMEOUT_SHORT)

    let response =
      await client.wakuPeerExchangeClient.request(requestedPeers, connOpt.get())
    assertResultOk(response)

    if uint64(response.get().peerInfos.len) > minimumPeers:
      return ok(response)

    attempts -= 1

  return err("Attempts exhausted.")
