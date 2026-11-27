{.used.}

import testutils/unittests, chronos, libp2p/[builders, switch]

import
  logos_delivery/waku/[waku_relay, waku_core],
  ../testlib/[common, wakunode, testasync],
  ./utils

const IdleTimeout = 1.seconds

proc newShortIdleSwitch(): Switch =
  SwitchBuilder
    .new()
    .withRng(rng())
    .withAddress(MultiAddress.init("/ip4/127.0.0.1/tcp/0").get())
    .withTcpTransport()
    .withYamux(inTimeout = IdleTimeout, outTimeout = IdleTimeout)
    .withNoise()
    .build()

proc meshedPair(
    keepAlive: Duration
): Future[(Switch, WakuRelay, Switch, WakuRelay)] {.async.} =
  let
    switchA = newShortIdleSwitch()
    switchB = newShortIdleSwitch()
    relayA = await newTestWakuRelay(switchA)
    relayB = await newTestWakuRelay(switchB)
  relayA.streamKeepAliveInterval = keepAlive
  relayB.streamKeepAliveInterval = keepAlive
  await allFutures(switchA.start(), switchB.start())
  await allFutures(relayA.start(), relayB.start())

  relayA.subscribe(DefaultPubsubTopic, noopRawHandler())
  relayB.subscribe(DefaultPubsubTopic, noopRawHandler())
  await switchA.connect(switchB.peerInfo.peerId, switchB.peerInfo.addrs)

  checkUntilTimeout:
    relayA.hasMeshPeer(DefaultPubsubTopic, switchB.peerInfo.peerId)
    relayB.hasMeshPeer(DefaultPubsubTopic, switchA.peerInfo.peerId)
  return (switchA, relayA, switchB, relayB)

suite "Waku Relay - send stream keepalive":
  asyncTest "an idle send stream is reset and the peer leaves the mesh":
    let (switchA, relayA, switchB, relayB) = await meshedPair(ZeroDuration)

    checkUntilTimeout:
      not relayA.hasMeshPeer(DefaultPubsubTopic, switchB.peerInfo.peerId)

    await allFutures(relayA.stop(), relayB.stop())
    await allFutures(switchA.stop(), switchB.stop())

  asyncTest "the keepalive keeps an idle peer in the mesh":
    let (switchA, relayA, switchB, relayB) = await meshedPair(IdleTimeout div 4)

    await sleepAsync(IdleTimeout * 5)

    check:
      relayA.hasMeshPeer(DefaultPubsubTopic, switchB.peerInfo.peerId)
      relayB.hasMeshPeer(DefaultPubsubTopic, switchA.peerInfo.peerId)

    await allFutures(relayA.stop(), relayB.stop())
    await allFutures(switchA.stop(), switchB.stop())
