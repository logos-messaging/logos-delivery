{.used.}

import
  std/options,
  testutils/unittests,
  chronos,
  libp2p/switch,
  libp2p/peerId,
  libp2p/crypto/crypto,
  eth/keys,
  eth/enr/enr

import
  waku/[
    waku_node,
    discovery/waku_discv5,
    waku_peer_exchange,
    waku_peer_exchange/rpc,
    waku_peer_exchange/protocol,
    waku_peer_exchange/client,
    node/peer_manager,
    waku_core,
  ],
  ../testlib/[futures, wakucore, assertions]

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
