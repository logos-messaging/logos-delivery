{.used.}

import
  testutils/unittests,
  chronos,
  libp2p/builders,
  libp2p/protocols/connectivity/autonat/client,
  libp2p/protocols/connectivity/relay/relay,
  libp2p/protocols/connectivity/relay/client,
  stew/byteutils
import waku/node/waku_switch, ./testlib/common, ./testlib/wakucore

proc newCircuitRelayClientSwitch(relayClient: RelayClient): Switch =
  SwitchBuilder
    .new()
    .withRng(rng())
    .withAddresses(@[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()])
    .withTcpTransport()
    .withMplex()
    .withNoise()
    .withCircuitRelay(relayClient)
    .build()

suite "Waku Switch":
  asyncTest "Waku Switch works with AutoNat":
    ## Given
    let
      sourceSwitch = newTestSwitch()
      wakuSwitch = newWakuSwitch(rng = rng(), circuitRelay = Relay.new())
    await sourceSwitch.start()
    await wakuSwitch.start()

    ## When
    await sourceSwitch.connect(wakuSwitch.peerInfo.peerId, wakuSwitch.peerInfo.addrs)
    let ma = await AutonatClient.new().dialMe(
      sourceSwitch, wakuSwitch.peerInfo.peerId, wakuSwitch.peerInfo.addrs
    )

    ## Then
    check:
      ma == sourceSwitch.peerInfo.addrs[0]

    ## Teardown
    await allFutures(sourceSwitch.stop(), wakuSwitch.stop())

  asyncTest "Waku Switch acts as circuit relayer":
    ## Setup
    let
      wakuSwitch = newWakuSwitch(rng = rng(), circuitRelay = Relay.new())
      sourceClient = RelayClient.new()
      destClient = RelayClient.new()
      sourceSwitch = newCircuitRelayClientSwitch(sourceClient)
      destSwitch = newCircuitRelayClientSwitch(destClient)

    # Setup client relays
    sourceClient.setup(sourceSwitch)
    destClient.setup(destSwitch)

    await allFutures(wakuSwitch.start(), sourceSwitch.start(), destSwitch.start())

    ## Given
    let
      # Create a relay address to destSwitch using wakuSwitch as the relay
      addrs = MultiAddress
        .init(
          $wakuSwitch.peerInfo.addrs[0] & "/p2p/" & $wakuSwitch.peerInfo.peerId &
            "/p2p-circuit"
        )
        .get()
      msg = "Just one relay away..."

    # Create a custom protocol
    let customProtoCodec = "/vac/waku/test/1.0.0"
    var
      completionFut = newFuture[bool]()
      proto = new LPProtocol
    proto.codec = customProtoCodec
    proto.handler = proc(
        conn: Connection, proto: string
    ) {.async: (raises: [CancelledError]).} =
      try:
        assert (await conn.readLp(1024)) == msg.toBytes()
      except LPStreamError:
        error "Connection read error", error = getCurrentExceptionMsg()
        assert false, getCurrentExceptionMsg()

      completionFut.complete(true)

    await proto.start()
    destSwitch.mount(proto)

    ## When
    # Connect destSwitch to the relay
    await destSwitch.connect(wakuSwitch.peerInfo.peerId, wakuSwitch.peerInfo.addrs)

    # Connect sourceSwitch to the relay
    await sourceSwitch.connect(wakuSwitch.peerInfo.peerId, wakuSwitch.peerInfo.addrs)

    # destClient reserves a slot on the relay.
    let rsvp =
      await destClient.reserve(wakuSwitch.peerInfo.peerId, wakuSwitch.peerInfo.addrs)

    # sourceSwitch dial destSwitch using the relay
    let conn =
      await sourceSwitch.dial(destSwitch.peerInfo.peerId, @[addrs], customProtoCodec)

    await conn.writeLp(msg)

    ## Then
    check:
      await completionFut.withTimeout(3.seconds)

    ## Teardown
    await allFutures(wakuSwitch.stop(), sourceSwitch.stop(), destSwitch.stop())
