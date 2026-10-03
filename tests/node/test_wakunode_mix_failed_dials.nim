{.used.}

## Failed dials and the mix pool (#4357, #4352).

import
  std/[net, sequtils, strutils],
  testutils/unittests,
  chronos,
  metrics,
  results,
  stew/byteutils,
  libp2p/[connmanager, multiaddress, peerid, peerinfo, peerstore, switch],
  libp2p/crypto/crypto,
  libp2p/stream/connection,
  libp2p_mix/mix_protocol
import
  logos_delivery/waku/[waku_core, waku_node, waku_mix, waku_lightpush],
  logos_delivery/waku/waku_mix/protocol_metrics,
  logos_delivery/waku/node/delivery_dialer,
  logos_delivery/waku/node/peer_manager,
  logos_delivery/waku/node/peer_manager/waku_peer_store,
  logos_delivery/waku/discovery/peer_discovery_interface,
  ../testlib/[futures, testasync, wakucore, wakumix]

suite "Waku Mix - failed reply hop dials":
  asyncTest "no dialable reply candidate gives a fast failure, nothing sent, then recovery":
    let net = await startMixNodes()
    let sender = await addNatSender(@[net.infos[0]])
    defer:
      await net.stop(@[sender])
    await net.connectExit(sender)
    let deadIds = sender.deadPeers(2)
    check sender.getMixNodePoolSize() == 3

    let failuresBefore = logos_delivery_mix_reply_hop_failures.value()
    # One send dials the two dead peers.
    let first = await net.send(sender, "dead-first")
    check:
      logos_delivery_mix_reply_hop_failures.value() == failuresBefore + 1
      not first.acked
      first.error.contains(NoReplyHopError)
      first.elapsed < MixReplyHopTimeout + chronos.seconds(1)
      not await net.published(first, FUTURE_TIMEOUT_SHORT)
      sender.wakuMix.surbCredsLen() == 0
      deadIds.allIt(sender.failed(it))
      sender.getMixNodePoolSize() == 1

    # With no candidate left, the next attempt stops before any dial.
    let second = await net.send(sender, "dead-second")
    check:
      logos_delivery_mix_reply_hop_failures.value() == failuresBefore + 2
      not second.acked
      not await net.published(second, FUTURE_TIMEOUT_SHORT)
      second.elapsed < chronos.seconds(1)
      deadIds.allIt(sender.failed(it))
      sender.wakuMix.surbCredsLen() == 0

    sender.wakuMix.addBootNodes(net.infos[1 ..^ 1])
    let third = await net.send(sender, "dead-recovered")
    check:
      third.acked
      await net.published(third)
      sender.wakuMix.surbCredsLen() == 0

  asyncTest "a sender with no connection counts no failed dial against any peer":
    let net = await startMixNodes()
    let sender = await addNatSender(@[net.infos[0]])
    defer:
      await net.stop(@[sender])
    let deadIds = sender.deadPeers(2)

    check sender.switch.connectedPeers().len == 0
    let isolated = await net.send(sender, "isolated-dead")
    check:
      not isolated.acked
      not await net.published(isolated, FUTURE_TIMEOUT_SHORT)
      sender.wakuMix.surbCredsLen() == 0
      deadIds.allIt(not sender.failed(it))
      sender.getMixNodePoolSize() == 3

  asyncTest "a later send joins the reply hop dial that is still running":
    let net = await startMixNodes()
    let accepted = new int
    let hanging = @[unresponsiveServer(accepted), unresponsiveServer(accepted)]
    let sender = await addNatSender(@[net.infos[0]])
    defer:
      await net.stop(@[sender])
      for server in hanging:
        server.stop()
        await server.closeWait()
    await net.connectExit(sender)
    let deadIds = sender.discoverAt(hanging[0].address(), hanging[1].address())

    let first = await net.send(sender, "joined-dial-1")
    let second = await net.send(sender, "joined-dial-2")
    check:
      not first.acked
      first.elapsed < MixReplyHopTimeout + chronos.seconds(1)
      not second.acked
    # One dial connected to each unresponsive server. The second send joined it.
    check:
      await accepted.staysAtMost(2, chronos.seconds(1))
      accepted[] == 2
    # The joined dials time out, and each one counts.
    checkUntilTimeoutCustom(DefaultDialTimeout, chronos.milliseconds(100)):
      deadIds.allIt(sender.failed(it))

  asyncTest "a send after mix stops dials nothing":
    let net = await startMixNodes()
    let sender = await addNatSender(@[net.infos[0]])
    defer:
      await net.stop(@[sender])
    await net.connectExit(sender)
    discard sender.deadPeers(2)

    await sender.wakuMix.stop()
    let outcome = await net.send(sender, "after-stop")
    check:
      not outcome.acked
      not await net.published(outcome, FUTURE_TIMEOUT_SHORT)
      outcome.error.contains(MixStoppingError)
      outcome.elapsed < chronos.seconds(1)

  asyncTest "a stop of mix ends the reply hop dials of a send":
    let net = await startMixNodes()
    let accepted = new int
    let hanging = @[unresponsiveServer(accepted), unresponsiveServer(accepted)]
    let sender = await addNatSender(@[net.infos[0]])
    defer:
      await net.stop(@[sender])
      for server in hanging:
        server.stop()
        await server.closeWait()
    await net.connectExit(sender)
    discard sender.discoverAt(hanging[0].address(), hanging[1].address())

    let sending = net.send(sender, "stop-during-dial")
    checkUntilTimeout:
      accepted[] == 2
    await sender.wakuMix.stop()
    let outcome = await sending
    check:
      not outcome.acked
      outcome.elapsed < chronos.seconds(2)
      not await net.published(outcome, FUTURE_TIMEOUT_SHORT)

  asyncTest "a blocked quic address does not hide a tcp address that works":
    ## The quic address drops every packet, as behind a firewall.
    let target = await startNodeWithoutMix()
    let node = await startMixNode(quicEnabled = true)
    let blackhole = newDatagramTransport(
      proc(t: DatagramTransport, a: TransportAddress) {.async: (raises: []).} =
        discard,
      local = initTAddress("127.0.0.1:0"),
    )
    defer:
      await blackhole.closeWait()
      await node.stop()
      await target.stop()

    let deadQuic = "/ip4/127.0.0.1/udp/" & $blackhole.localAddress().port & "/quic-v1"
    let targetId =
      node.discover(@[deadQuic, target.tcpAddress()], target.peerInfo.peerId)
    check $node.hopOf(targetId) == deadQuic

    let exitId = PeerId.init(generateSecp256k1Key()).tryGet()
    let started = Moment.now()
    check (await node.wakuMix.prepareReplyPath(exitId)).isOk()
    check:
      Moment.now() - started < MixReplyHopTimeout
      $node.hopOf(targetId) == target.tcpAddress()

suite "Waku Mix - unreachable pool members":
  asyncTest "a peer with a failed dial stays off paths, also after discovery finds it again":
    let net = await startMixNodes()
    let sender = await addNatSender(net.infos)
    defer:
      await net.stop(@[sender])
    for i in 0 ..< MixNodeCount:
      await sender.switch.connect(
        net.nodes[i].peerInfo.peerId, net.nodes[i].peerInfo.addrs
      )

    let dead = sender.discover(@[DeadAddress])
    check sender.getMixNodePoolSize() == MixNodeCount + 1
    sender.wakuMix.pool.countFailure(dead)
    check sender.getMixNodePoolSize() == MixNodeCount

    # Discovery does not clear the failed dial.
    sender.discover(@[DeadAddress], dead)
    check sender.getMixNodePoolSize() == MixNodeCount

    for i in 0 ..< 4:
      let outcome = await net.send(sender, "known-dead-" & $i)
      check:
        outcome.acked
        await net.published(outcome)
        sender.wakuMix.surbCredsLen() == 0

  asyncTest "a failed dial to the first hop takes that peer out of the pool":
    ## Each candidate for the first hop is unreachable.
    let net = await startMixNodes()
    let sender = await addNatSender(@[net.infos[0]])
    defer:
      await net.stop(@[sender])
    await net.connectExit(sender)
    let deadIds = sender.deadPeers(3)

    let sent = await sender.wakuMix.anonymizeLocalProtocolSend(
      newAsyncQueue[seq[byte]](),
      toBytes("first-hop"),
      WakuLightPushCodec,
      MixDestination.exitNode(net.exit.peerInfo.peerId),
      0'u8,
    )
    check sent.isErr()
    let failed = deadIds.filterIt(sender.failed(it))
    check failed.len == 1
    if failed.len == 1:
      check:
        not sender.inPool(failed[0])
        sender.getMixNodePoolSize() == 3
        deadIds.filterIt(it != failed[0]).allIt(not sender.failed(it))

  asyncTest "a first hop that never answers leaves the pool when the send cancels its dial":
    let net = await startMixNodes()
    let servers = @[unresponsiveServer(), unresponsiveServer(), unresponsiveServer()]
    let sender = await addNatSender(@[net.infos[0]])
    defer:
      await net.stop(@[sender])
      for server in servers:
        server.stop()
        await server.closeWait()
    await net.connectExit(sender)
    let deadIds = sender.discoverAt(servers.mapIt(it.address()))

    # `withTimeout` cancels the send, as `publishOverMix` does.
    let sending = sender.wakuMix.anonymizeLocalProtocolSend(
      newAsyncQueue[seq[byte]](),
      toBytes("unresponsive-first-hop"),
      WakuLightPushCodec,
      MixDestination.exitNode(net.exit.peerInfo.peerId),
      0'u8,
    )
    check not await sending.withTimeout(chronos.seconds(1))
    checkUntilTimeout:
      deadIds.anyIt(sender.failed(it))
    let failed = deadIds.filterIt(sender.failed(it))
    check failed.len == 1
    if failed.len == 1:
      check:
        not sender.inPool(failed[0])
        deadIds.filterIt(it != failed[0]).allIt(not sender.failed(it))

suite "Waku Mix - failed dials and the backoff":
  asyncTest "a missing reply records nothing against any peer":
    let hook = ExitHook.new()
    let net = await startMixNodes(hook)
    # A failed dial counts only for a discovered node.
    let sender = await addNatSender(@[])
    for entry in net.infos:
      sender.discoverNode(entry)
    let other = await sender.addOtherConnection()
    defer:
      await other.stop()
      await net.stop(@[sender])
    check sender.getMixNodePoolSize() == MixNodeCount

    # The sender loses its connections while the request is at the exit.
    await net.connectOnly(sender, 1)
    let sending = net.send(sender, "missing-reply")
    check await hook.requested.wait().withTimeout(chronos.seconds(5))
    await net.disconnectAll(sender)
    hook.reply.fire()

    let lost = await sending
    check:
      not lost.acked
      lost.error.contains("timed out")
      await net.published(lost)
      net.nodes.allIt(not sender.failed(it.peerInfo.peerId))
      sender.getMixNodePoolSize() == MixNodeCount

  asyncTest "a failed mix stream dial counts only for a pool peer at its hop":
    ## nim-libp2p-mix also dials addresses that another node chose.
    let node = await startMixNode()
    let other = await node.addOtherConnection()
    defer:
      await node.stop()
      await other.stop()
    let dead = MultiAddress.init(DeadAddress).tryGet()
    let otherDead = MultiAddress.init("/ip4/127.0.0.1/tcp/2").tryGet()
    let mixPeer = node.discover(@[$dead])
    let lightpushPeer = node.discover(@[$dead])
    let packetAddressPeer = node.discover(@[$dead])
    let lateMixPeer = node.discover(@[$dead])
    let unknown = PeerId.init(generateSecp256k1Key()).tryGet()
    let failuresBefore = logos_delivery_mix_dial_failures.value()

    proc dialFails(
        peerId: PeerId, codec: string, address = dead
    ): Future[bool] {.async.} =
      try:
        discard await node.switch.dial(peerId, @[address], @[codec])
        return false
      except DialFailedError:
        return true

    check:
      await dialFails(mixPeer, MixProtocolID)
      await dialFails(lightpushPeer, WakuLightPushCodec)
      await dialFails(unknown, MixProtocolID)
      await dialFails(packetAddressPeer, MixProtocolID, otherDead)
    check:
      node.failed(mixPeer)
      not node.inPool(mixPeer)
      not node.failed(lightpushPeer)
      node.inPool(lightpushPeer)
      not node.failed(unknown)
      not node.failed(packetAddressPeer)
      node.inPool(packetAddressPeer)

    # The peer is out of the pool, so a second failure does not count.
    check:
      await dialFails(mixPeer, MixProtocolID)
      node.failed(mixPeer)

    # After the pool stops, it records no failure.
    await node.wakuMix.pool.stop()
    check:
      await dialFails(lateMixPeer, MixProtocolID)
      not node.failed(lateMixPeer)
      logos_delivery_mix_dial_failures.value() == failuresBefore + 1

  asyncTest "a cancelled mix dial at another address records nothing":
    let accepted = new int
    let hanging = unresponsiveServer(accepted)
    let node = await startMixNode()
    let other = await node.addOtherConnection()
    defer:
      await node.stop()
      await other.stop()
      hanging.stop()
      await hanging.closeWait()
    let peerId = node.discover(@[DeadAddress])
    let packetAddress = MultiAddress.init(hanging.address()).tryGet()

    let cancelled = node.switch.dial(peerId, @[packetAddress], @[MixProtocolID])
    checkUntilTimeout:
      accepted[] == 1
    # The dial runs its handlers before `cancelAndWait` returns.
    await cancelled.cancelAndWait()
    check:
      not node.failed(peerId)
      node.inPool(peerId)

  asyncTest "a stream that fails on an existing connection records nothing":
    ## The peer does not serve mix.
    let target = await startNodeWithoutMix()
    let node = await startMixNode()
    let other = await node.addOtherConnection()
    defer:
      await node.stop()
      await target.stop()
      await other.stop()
    let targetId = target.peerInfo.peerId
    let address = MultiAddress.init(target.tcpAddress()).tryGet()
    node.discover(@[$address], targetId)
    await node.switch.connect(targetId, @[address])
    check node.inPool(targetId)

    expect DialFailedError:
      discard await node.switch.dial(targetId, @[address], @[MixProtocolID])
    check:
      node.switch.isConnected(targetId)
      not node.failed(targetId)
      node.inPool(targetId)

  asyncTest "a peer with a failed dial returns to paths after the backoff, with no dial":
    let accepted = new int
    let server = unresponsiveServer(accepted)
    let node = await startMixNode()
    defer:
      await node.stop()
      server.stop()
      await server.closeWait()
    let peerId = node.discover(@[server.address()])
    node.wakuMix.pool.countFailure(peerId)
    node.wakuMix.pool.maintain()
    check not node.inPool(peerId)

    node.wakuMix.pool.failureBackoff = ZeroDuration
    node.wakuMix.pool.maintain()
    check:
      node.inPool(peerId)
      not node.failed(peerId)
      await accepted.staysAtMost(0)

  asyncTest "the pool loop returns a peer with a failed dial while mix runs":
    let node = await startMixNode(poolLoopInterval = chronos.milliseconds(100))
    defer:
      await node.stop()
    let peerId = node.discover(@["/ip4/1.1.3.3/tcp/30303"])
    node.wakuMix.pool.failureBackoff = chronos.milliseconds(300)
    node.wakuMix.pool.countFailure(peerId)
    check not node.inPool(peerId)

    checkUntilTimeout:
      node.inPool(peerId)

  asyncTest "a dial that the connection limit of this node refuses records nothing":
    let node = await startMixNode()
    let other = await node.addOtherConnection()
    # Take each free connection slot of this node.
    var slots: seq[ConnectionSlot]
    for _ in 0 ..< 10_000:
      try:
        slots.add(node.switch.connManager.getOutgoingSlot())
      except TooManyConnectionsError:
        break
    defer:
      for slot in slots:
        slot.release()
      await node.stop()
      await other.stop()
    let streamPeer = node.discover(@[DeadAddress])
    let replyPeer = node.discover(@[DeadAddress])

    var refused = false
    try:
      discard await node.switch.dial(
        streamPeer, @[MultiAddress.init(DeadAddress).tryGet()], @[MixProtocolID]
      )
    except DialFailedError as exc:
      refused = exc.connectionLimitReached()
    check:
      refused
      not await node.wakuMix.pool.dial(replyPeer)
      not node.failed(streamPeer)
      not node.failed(replyPeer)
      node.inPool(streamPeer)
      node.inPool(replyPeer)

  asyncTest "a failed dial drops the last dialed address, so the hop follows the record":
    let node = await mixNode()
    let store = node.switch.peerStore
    let peerId = PeerId.init(generateSecp256k1Key()).tryGet()
    # An outbound connection before the mix key gives the first hop.
    store[LastSeenOutboundBook][peerId] =
      Opt.some(MultiAddress.init("/ip4/1.1.1.6/tcp/30304").tryGet())
    node.discover(@["/ip4/1.1.1.5/tcp/30303"], peerId)
    check $node.hopOf(peerId) == "/ip4/1.1.1.6/tcp/30304"

    # The node moves. Its new record does not change the hop.
    node.discover(@["/ip4/1.1.1.7/tcp/30303"], peerId)
    check $node.hopOf(peerId) == "/ip4/1.1.1.6/tcp/30304"

    # A failed dial at the old address drops it, and the next record does not
    # bring it back.
    node.wakuMix.pool.countFailure(peerId)
    node.wakuMix.pool.failureBackoff = ZeroDuration
    node.wakuMix.pool.maintain()
    node.discover(@["/ip4/1.1.1.7/tcp/30303"], peerId)
    check $node.hopOf(peerId) == "/ip4/1.1.1.7/tcp/30303"

    # A new outbound connection gives the hop again.
    store[LastSeenOutboundBook][peerId] =
      Opt.some(MultiAddress.init("/ip4/1.1.1.8/tcp/30304").tryGet())
    check $node.hopOf(peerId) == "/ip4/1.1.1.8/tcp/30304"

  asyncTest "a failed dial drops the last dialed address of a configured node":
    let configured = bootnode("/ip4/1.2.3.4/tcp/30303")
    let node = await mixNode(bootnodes = @[configured])
    node.switch.peerStore[LastSeenOutboundBook][configured.peerId] =
      Opt.some(MultiAddress.init("/ip4/1.2.3.10/tcp/30303").tryGet())
    check $node.hopOf(configured.peerId) == "/ip4/1.2.3.10/tcp/30303"

    node.wakuMix.pool.countFailure(configured.peerId)
    check:
      not node.failed(configured.peerId)
      $node.hopOf(configured.peerId) == "/ip4/1.2.3.4/tcp/30303"
