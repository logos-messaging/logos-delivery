{.used.}

import std/[times, tables]
import brokers/broker_context
import testutils/unittests, chronos, results
import
  libp2p/[
    peerstore,
    peerid,
    multiaddress,
    crypto/crypto,
    switch,
    stream/connection,
    stream/lpstream,
  ]
import libp2p_mix
import libp2p_mix/mix_protocol
import libp2p/crypto/curve25519
import libp2p_mix/[mix_pool, external_pool, pool, curve25519]
import
  logos_delivery/waku/[
    node/waku_node,
    node/waku_node/lightpush,
    node/peer_manager,
    node/peer_manager/waku_peer_store,
    waku_core,
    waku_mix,
  ]
import ../testlib/[wakucore, wakunode, testasync]

proc newTestNode(): Future[WakuNode] {.async.} =
  lockNewGlobalBrokerContext:
    return newTestWakuNode(generateSecp256k1Key(), parseIpAddress("127.0.0.1"), Port(0))

proc candidate(address = "/ip4/8.8.8.8/tcp/60000"): RemotePeerInfo =
  let identity = generateSecp256k1Key()
  RemotePeerInfo.init(
    PeerId.init(identity.getPublicKey().get()).get(),
    @[MultiAddress.init(address).get()],
    protocols = @["/vac/waku/relay/2.0.0"],
    publicKey = identity.getPublicKey().get(),
    mixPubKey = Opt.some(generateKeyPair().get().publicKey),
  )

suite "Delivery provides the mix peers":
  asyncTest "peer providers belong to each manager":
    let first = await newTestNode()
    let second = await newTestNode()
    defer:
      first.peerManager.stop()
      second.peerManager.stop()
    first.peerManager.configureMix(true).get()
    second.peerManager.configureMix().get()
    let peer = candidate("/ip4/127.0.0.1/tcp/60000")
    first.peerManager.addPeer(peer)
    second.peerManager.addPeer(peer)
    check:
      first.brokerCtx != second.brokerCtx
      first.peerManager.mixPool.countUsable([]).get() == 1
      second.peerManager.mixPool.countUsable([]).get() == 0
    first.peerManager.stop()
    check:
      not ListMixPeerIds.isProvided(first.brokerCtx)
      ListMixPeerIds.isProvided(second.brokerCtx)

  asyncTest "node restart registers peer providers before restarting mix":
    let node = await newTestNode()
    let keys = generateKeyPair().get()
    (
      await node.mountMix(
        DefaultClusterId, keys.privateKey, @[], allowAllAddresses = true
      )
    ).expect("mount")
    let ctx = node.brokerCtx
    let peer = candidate("/ip4/127.0.0.1/tcp/60000")
    node.peerManager.addPeer(peer)
    await node.start()
    await node.stop()
    check:
      not ReadMixPeer.isProvided(ctx)
      not SelectMixReplyPeer.isProvided(ctx)
      node.getMixNodePoolSize() == 0
      node.switch.peerStore[MixPubKeyBook][peer.peerId] == peer.mixPubKey.get()
    await node.start()
    try:
      check:
        ReadMixPeer.isProvided(ctx)
        SelectMixReplyPeer.isProvided(ctx)
        node.wakuMix.poolSize() == 1
        node.wakuMix.selfHopUsable()
    finally:
      await node.stop()
    check not ReadMixPeer.isProvided(ctx)

  asyncTest "mount uses the host store and sees subsequent discovery without copying":
    let node = await newTestNode()
    defer:
      node.peerManager.stop()
    let keys = generateKeyPair().get()
    (await node.mountMix(DefaultClusterId, keys.privateKey, @[])).expect("mount")
    check node.wakuMix.pool == MixPool(node.peerManager.mixPool)
    let peer = candidate()
    check node.wakuMix.poolSize() == 0
    node.peerManager.addPeer(peer)
    check:
      node.wakuMix.poolSize() == 1
      node.wakuMix.pool.usablePeer(peer.peerId).get().get().mixPubKey ==
        peer.mixPubKey.get()
    let replacement = generateKeyPair().get().publicKey
    peer.mixPubKey = Opt.some(replacement)
    node.peerManager.addPeer(peer)
    check node.wakuMix.pool.usablePeer(peer.peerId).get().get().mixPubKey == replacement
    peer.mixPubKey = Opt.some(default(Curve25519Key))
    node.peerManager.addPeer(peer)
    check node.wakuMix.poolSize() == 0
    node.wakuMix.addBootNodes(
      @[
        MixNodePubInfo(
          multiAddr: $peer.addrs[0] & "/p2p/" & $peer.peerId, pubKey: replacement
        )
      ]
    )
    check:
      node.wakuMix.poolSize() == 1
      node.switch.peerStore[SourceBook][peer.peerId] == Static
      node.switch.peerStore[AddressBook].book[peer.peerId][0].confidence ==
        AddressConfidence.Infinite
    await node.stop()

  asyncTest "exclusion, recovery and store mutations preserve non-mix peer information":
    let node = await newTestNode()
    defer:
      node.peerManager.stop()
    let store = node.switch.peerStore
    node.peerManager.configureMix().get()
    let pool = node.peerManager.mixPool
    let peer = candidate()
    node.peerManager.addPeer(peer)
    store.excludeFromMix(peer.peerId)
    check:
      pool.countUsable([]).get() == 0
      pool.usablePeer(peer.peerId).get().isNone()
      store.getPeer(peer.peerId).protocols == peer.protocols
      store.getPeer(peer.peerId).mixPubKey == peer.mixPubKey
    store.excludeFromMix(peer.peerId, false)
    let info = pool.usablePeer(peer.peerId).get().get()
    check pool.countUsable([]).get() == 1
    check node.peerManager.removeMixPeer(peer.peerId)
    check:
      pool.countUsable([]).get() == 0
      store[AddressBook][peer.peerId] == peer.addrs
      store[KeyBook][peer.peerId] == peer.publicKey
    node.peerManager.storeMixPeer(info)
    check:
      pool.countUsable([]).get() == 1
      store[MixPubKeyBook][peer.peerId] == info.mixPubKey
      store[ProtoBook][peer.peerId] == peer.protocols

  asyncTest "strict policy filters outbound hints too; permissive policy is host owned":
    let node = await newTestNode()
    defer:
      node.peerManager.stop()
    let peer = candidate()
    node.peerManager.addPeer(peer)
    let store = node.switch.peerStore
    node.peerManager.configureMix().get()
    let pool = node.peerManager.mixPool
    let loopback = MultiAddress.init("/ip4/127.0.0.1/tcp/60000").get()
    store[LastSeenOutboundBook][peer.peerId] = Opt.some(loopback)
    check pool.usablePeer(peer.peerId).get().get().multiAddr == peer.addrs[0]
    node.peerManager.configureMix(true).get()
    check pool.usablePeer(peer.peerId).get().get().multiAddr == loopback
    for address in [
      "/ip4/10.0.0.1/tcp/60000",
      "/ip4/224.0.0.1/tcp/60000",
      "/ip4/8.8.8.8/tcp/0",
      "/ip4/8.8.8.8/tcp/60000/p2p/" & $peer.peerId & "/p2p-circuit",
    ]:
      let parsed = MultiAddress.init(address).get()
      check:
        not parsed.acceptsMixAddress()
        parsed.acceptsMixAddress(allowAllAddresses = true)
    discard store[AddressBook].del(peer.peerId)
    node.peerManager.configureMix(false).get()
    check pool.countUsable([]).get() == 0
    node.peerManager.configureMix(true).get()
    check:
      pool.countUsable([]).get() == 1
      store[KeyBook][peer.peerId] == peer.publicKey

  asyncTest "discovery expiry and renewed evidence change mix membership without deleting keys":
    let node = await newTestNode()
    defer:
      node.peerManager.stop()
    let peer = candidate()
    node.peerManager.addPeer(peer, Kademlia)
    let store = node.switch.peerStore
    node.peerManager.configureMix().get()
    let pool = node.peerManager.mixPool
    check pool.countUsable([]).get() == 1
    store[MixAliveBook][peer.peerId] =
      Moment.now() - DiscoveredEnrTtl - chronos.seconds(1)
    check pool.countUsable([]).get() == 0
    check store[MixPubKeyBook][peer.peerId] == peer.mixPubKey.get()
    node.peerManager.addPeer(peer, Kademlia)
    check pool.countUsable([]).get() == 1

  asyncTest "configured keys stay durable through discovery and key updates":
    let node = await newTestNode()
    defer:
      node.peerManager.stop()
    let peer = candidate()
    node.peerManager.addPeer(peer, Static)
    let store = node.switch.peerStore
    node.peerManager.configureMix().get()
    let pool = node.peerManager.mixPool
    node.peerManager.addPeer(
      RemotePeerInfo.init(peer.peerId, peer.addrs, publicKey = peer.publicKey), Discv5
    )
    check store[SourceBook][peer.peerId] == Discv5
    check pool.countUsable([]).get() == 1
    peer.mixPubKey = Opt.some(generateKeyPair().get().publicKey)
    node.peerManager.addPeer(peer, Kademlia)
    check:
      store[MixAliveBook][peer.peerId] == Moment()
      store[MixPubKeyBook][peer.peerId] == peer.mixPubKey.get()
      pool.countUsable([]).get() == 1

  asyncTest "reflected records do not renew discovery and removal clears key provenance":
    let node = await newTestNode()
    defer:
      node.peerManager.stop()
    let peer = candidate()
    node.peerManager.addPeer(peer, Kademlia)
    let store = node.switch.peerStore
    node.peerManager.configureMix().get()
    let pool = node.peerManager.mixPool
    let old = Moment.now() - DiscoveredEnrTtl - chronos.seconds(1)
    store[MixAliveBook][peer.peerId] = old
    node.peerManager.addServicePeer(store.getPeer(peer.peerId), WakuLightPushCodec)
    check store[MixAliveBook][peer.peerId] == old
    check pool.countUsable([]).get() == 0
    check node.peerManager.removeMixPeer(peer.peerId)
    check store[MixAliveBook][peer.peerId] == Moment()
    node.peerManager.addPeer(peer, Kademlia)
    check store[MixAliveBook][peer.peerId] != Moment()
    check node.peerManager.removeMixPeer(peer.peerId)
    node.peerManager.addPeer(peer)
    check:
      store[MixAliveBook][peer.peerId] == Moment()
      pool.countUsable([]).get() == 1

  asyncTest "the source obeys existing Delivery connection backoff and its expiry":
    let node = await newTestNode()
    defer:
      node.peerManager.stop()
    let peer = candidate()
    node.peerManager.addPeer(peer)
    let store = node.switch.peerStore
    node.peerManager.configureMix().get()
    let pool = node.peerManager.mixPool
    let now = Moment.init(getTime().toUnix(), Second)
    store[NumberFailedConnBook][peer.peerId] = 1
    store[LastFailedConnBook][peer.peerId] = now
    check pool.countUsable([]).get() == 0
    store[LastFailedConnBook][peer.peerId] = Moment.init(1, Second)
    check pool.countUsable([]).get() == 1
    # `connectPeer` does not dial a peer with `maxFailedAttempts` failures
    # again. Mix waits the longest backoff and then selects the peer again.
    store[NumberFailedConnBook][peer.peerId] = node.peerManager.maxFailedAttempts
    store[LastFailedConnBook][peer.peerId] = now
    check:
      pool.countUsable([]).get() == 0
      not node.peerManager.canBeConnected(peer.peerId)
    store[LastFailedConnBook][peer.peerId] = Moment.init(1, Second)
    check:
      pool.countUsable([]).get() == 1
      not node.peerManager.canBeConnected(peer.peerId)
      store[MixPubKeyBook][peer.peerId] == peer.mixPubKey.get()

  asyncTest "default address policy admits a private own hop but not private peers":
    let node = await newTestNode()
    let keys = generateKeyPair().get()
    (await node.mountMix(DefaultClusterId, keys.privateKey, @[])).get()
    defer:
      node.peerManager.stop()
    # A public QUIC-v1 endpoint is accepted like a public TCP endpoint.
    node.peerManager.addPeer(candidate("/ip4/8.8.4.4/udp/60000/quic-v1"))
    check node.wakuMix.poolSize() == 1
    for address in ["/ip4/127.0.0.1/tcp/60000", "/ip4/192.168.1.2/tcp/60000"]:
      let hop = MultiAddress.init(address).get()
      check node.wakuMix.updateSelfHop(@[hop], @[]).isSome()
      check node.wakuMix.selfHopUsable()
      node.peerManager.addPeer(candidate(address))
      check node.wakuMix.poolSize() == 1

suite "Delivery selection of the final reply peer":
  asyncTest "a connected exit is excluded and Delivery connects one eligible peer and reuses it":
    let sender = await newTestNode()
    let exit = await newTestNode()
    let first = await newTestNode()
    let second = await newTestNode()
    let keys = generateKeyPair().get()
    (
      await sender.mountMix(
        DefaultClusterId, keys.privateKey, @[], allowAllAddresses = true
      )
    ).expect("mount")
    await sender.start()
    await exit.start()
    await first.start()
    await second.start()
    defer:
      await sender.stop()
      await exit.stop()
      await first.stop()
      await second.stop()
    for node in [exit, first, second]:
      let peer = node.peerInfo.toRemotePeerInfo()
      peer.mixPubKey = Opt.some(generateKeyPair().get().publicKey)
      sender.peerManager.addPeer(peer)
    await sender.switch.connect(exit.peerInfo.peerId, exit.peerInfo.addrs)
    let excluded = @[sender.peerInfo.peerId, exit.peerInfo.peerId]
    let candidates = [first.peerInfo.peerId, second.peerInfo.peerId]
    let selected = (await sender.wakuMix.selectReplyPeer(excluded)).get()
    check:
      selected in candidates
      sender.switch.isConnected(selected)
      sender.switch.connectedPeers().len == 2
    # The connected set now has one eligible member, and it is reused.
    for _ in 0 ..< 8:
      check (await sender.wakuMix.selectReplyPeer(excluded)).get() == selected

  asyncTest "Delivery bounds stalled reply preparation without retaining credentials":
    # The server accepts each connection and never answers, so the dial stalls.
    var accepted: seq[StreamTransport]
    let ready = newAsyncEvent()
    let server = createStreamServer(
      initTAddress("127.0.0.1:0"),
      proc(server: StreamServer, client: StreamTransport) {.async: (raises: []).} =
        accepted.add(client)
        ready.fire(),
    )
    server.start()
    defer:
      server.stop()
      await server.closeWait()
      for transport in accepted:
        await transport.closeWait()
    let node = await newTestNode()
    let key = generateKeyPair().get()
    (
      await node.mountMix(
        DefaultClusterId,
        key.privateKey,
        @[],
        allowAllAddresses = true,
        replyPeerTimeout = chronos.milliseconds(50),
      )
    ).expect("mount mix")
    # The mix lightpush time limit follows the configured reply peer timeout.
    check node.mixReplyTimeout() == chronos.milliseconds(50) + MixPathTimeout
    await node.start()
    defer:
      await node.stop()
    for _ in 0 ..< 4:
      node.peerManager.addPeer(
        candidate("/ip4/127.0.0.1/tcp/" & $server.localAddress().port)
      )
    const Codec = "/test/delivery-reply/1"
    node.wakuMix.registerDestReadBehavior(Codec, readLp(1024))
    let conn = node.wakuMix
      .toConnection(
        MixDestination.exitNode(node.wakuMix.pool.listPeerIds().get()[^1]),
        Codec,
        MixParameters(expectReply: Opt.some(true), numSurbs: Opt.some(2'u8)),
      )
      .get()
    defer:
      await conn.close()
    let writing = conn.writeLp(@[1'u8])
    await ready.wait().wait(chronos.seconds(2))
    expect LPStreamError:
      await writing.wait(chronos.seconds(2))
    check:
      node.wakuMix.surbCredsLen == 0
