{.used.}

## Failed reply hop dials (#4357).

import
  std/[net, strutils],
  testutils/unittests,
  chronos,
  metrics,
  results,
  libp2p/[multiaddress, peerid, peerinfo, switch],
  libp2p/crypto/crypto,
  libp2p/stream/connection,
  libp2p_mix/mix_protocol
import
  logos_delivery/waku/[waku_node, waku_mix],
  logos_delivery/waku/waku_mix/protocol_metrics,
  logos_delivery/waku/node/peer_manager,
  logos_delivery/waku/node/peer_manager/waku_peer_store,
  logos_delivery/waku/discovery/peer_discovery_interface,
  ../testlib/[futures, testasync, wakucore, wakumix]

suite "Waku Mix - failed reply hop dials":
  asyncTest "no dialable reply candidate gives a fast failure, and nothing is sent":
    let net = await startMixNodes()
    let sender = await addNatSender(@[net.infos[0]])
    defer:
      await net.stop(@[sender])
    await net.connectExit(sender)
    discard sender.deadPeers(2)
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

    let second = await net.send(sender, "dead-second")
    check:
      logos_delivery_mix_reply_hop_failures.value() == failuresBefore + 2
      not second.acked
      not await net.published(second, FUTURE_TIMEOUT_SHORT)
      second.elapsed < chronos.seconds(1)
      sender.wakuMix.surbCredsLen() == 0

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
    discard sender.discoverAt(hanging[0].address(), hanging[1].address())

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
