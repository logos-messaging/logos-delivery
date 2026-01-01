{.used.}

import
  std/[sequtils, strutils, net],
  stew/byteutils,
  testutils/unittests,
  chronicles,
  chronos,
  libp2p/crypto/crypto,
  libp2p/crypto/secp,
  libp2p/multiaddress,
  libp2p/switch,
  libp2p/protocols/pubsub/rpc/messages,
  libp2p/protocols/pubsub/pubsub,
  libp2p/protocols/pubsub/gossipsub,
  libp2p/nameresolving/mockresolver,
  eth/enr/enr,
  eth/net/utils
import
  waku/[waku_core, waku_node, node/peer_manager], ./testlib/wakucore, ./testlib/wakunode

suite "WakuNode":
  asyncTest "Protocol matcher works as expected":
    let
      nodeKey1 = generateSecp256k1Key()
      node1 = newTestWakuNode(nodeKey1, parseIpAddress("0.0.0.0"), Port(61000))
      nodeKey2 = generateSecp256k1Key()
      node2 = newTestWakuNode(nodeKey2, parseIpAddress("0.0.0.0"), Port(61002))
      shard = DefaultRelayShard
      contentTopic = ContentTopic("/waku/2/default-content/proto")
      payload = "hello world".toBytes()
      message = WakuMessage(payload: payload, contentTopic: contentTopic)

    # Setup node 1 with stable codec "/vac/waku/relay/2.0.0"

    await node1.start()
    (await node1.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    node1.wakuRelay.codec = "/vac/waku/relay/2.0.0"

    # Setup node 2 with beta codec "/vac/waku/relay/2.0.0-beta2"

    await node2.start()
    (await node2.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    node2.wakuRelay.codec = "/vac/waku/relay/2.0.0-beta2"

    check:
      # Check that mounted codecs are actually different
      node1.wakuRelay.codec == "/vac/waku/relay/2.0.0"
      node2.wakuRelay.codec == "/vac/waku/relay/2.0.0-beta2"

    # Now verify that protocol matcher returns `true` and relay works
    await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])

    var completionFut = newFuture[bool]()
    proc relayHandler(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      check:
        topic == $shard
        msg.contentTopic == contentTopic
        msg.payload == payload
      completionFut.complete(true)

    ## The following unsubscription is necessary to remove the default relay handler, which is
    ## added when mountRelay is called.
    node2.unsubscribe((kind: PubsubUnsub, topic: $shard)).isOkOr:
      assert false, "Failed to unsubscribe from topic: " & $error

    ## Subscribe to the relay topic to add the custom relay handler defined above
    node2.subscribe((kind: PubsubSub, topic: $shard), relayHandler).isOkOr:
      assert false, "Failed to subscribe to topic"
    await sleepAsync(2000.millis)

    var res = await node1.publish(some($shard), message)
    assert res.isOk(), $res.error

    await sleepAsync(2000.millis)

    check:
      (await completionFut.withTimeout(5.seconds)) == true

    await allFutures(node1.stop(), node2.stop())

  asyncTest "resolve and connect to dns multiaddrs":
    let resolver = MockResolver.new()

    resolver.ipResponses[("localhost", false)] = @["127.0.0.1"]

    let
      nodeKey1 = generateSecp256k1Key()
      node1 = newTestWakuNode(
        nodeKey1, parseIpAddress("0.0.0.0"), Port(61020), nameResolver = resolver
      )
      nodeKey2 = generateSecp256k1Key()
      node2 = newTestWakuNode(nodeKey2, parseIpAddress("0.0.0.0"), Port(61022))

    # Construct DNS multiaddr for node2
    let
      node2PeerId = $(node2.switch.peerInfo.peerId)
      node2Dns4Addr = "/dns4/localhost/tcp/61022/p2p/" & node2PeerId

    (await node1.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    (await node2.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"

    await allFutures([node1.start(), node2.start()])

    await node1.connectToNodes(@[node2Dns4Addr])

    check:
      node1.switch.connManager.connCount(node2.switch.peerInfo.peerId) == 1

    await allFutures([node1.stop(), node2.stop()])

  asyncTest "Maximum connections can be configured with 20 nodes":
    let
      maxConnections = 20
      nodeKey1 = generateSecp256k1Key()
      node1 = newTestWakuNode(
        nodeKey1,
        parseIpAddress("127.0.0.1"),
        Port(60010),
        maxConnections = maxConnections,
      )

    # Initialize and start node1
    await node1.start()
    (await node1.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"

    # Create an array to hold the other nodes
    var otherNodes: seq[WakuNode] = @[]

    # Create and start 20 other nodes
    for i in 0 ..< maxConnections + 1:
      let
        nodeKey = generateSecp256k1Key()
        port = 60012 + i * 2 # Ensure unique ports for each node
        node = newTestWakuNode(nodeKey, parseIpAddress("127.0.0.1"), Port(port))
      await node.start()
      (await node.mountRelay()).isOkOr:
        assert false, "Failed to mount relay"
      otherNodes.add(node)

    # Connect all other nodes to node1
    for node in otherNodes:
      discard
        await node1.peerManager.connectPeer(node.switch.peerInfo.toRemotePeerInfo())
      await sleepAsync(2.seconds) # Small delay to avoid hammering the connection process

    # Check that the number of connections matches the maxConnections
    check:
      node1.switch.isConnected(otherNodes[0].switch.peerInfo.peerId)
      node1.switch.isConnected(otherNodes[8].switch.peerInfo.peerId)
      node1.switch.isConnected(otherNodes[14].switch.peerInfo.peerId)
      node1.switch.isConnected(otherNodes[20].switch.peerInfo.peerId) == false

    # Stop all nodes
    var stopFutures = @[node1.stop()]
    for node in otherNodes:
      stopFutures.add(node.stop())
    await allFutures(stopFutures)

  asyncTest "Messages fails with wrong key path":
    let nodeKey1 = generateSecp256k1Key()

    expect ResultDefect:
      # gibberish
      discard newTestWakuNode(
        nodeKey1,
        parseIpAddress("0.0.0.0"),
        bindPort = Port(61004),
        wsBindPort = Port(8000),
        wssEnabled = true,
        secureKey = "../../waku/node/key_dummy.txt",
      )

  asyncTest "Peer info updates with correct announced addresses":
    let
      nodeKey = generateSecp256k1Key()
      bindIp = parseIpAddress("0.0.0.0")
      bindPort = Port(61006)
      extIp = some(getPrimaryIPAddr())
      extPort = some(Port(61008))
      node = newTestWakuNode(nodeKey, bindIp, bindPort, extIp, extPort)

    let
      bindEndpoint = MultiAddress.init(bindIp, tcpProtocol, bindPort)
      announcedEndpoint = MultiAddress.init(extIp.get(), tcpProtocol, extPort.get())

    check:
      # Check that underlying peer info contains only bindIp before starting
      node.switch.peerInfo.listenAddrs.len == 1
      node.switch.peerInfo.listenAddrs.contains(bindEndpoint)
      # Underlying peer info has not updated addrs before starting
      node.switch.peerInfo.addrs.len == 0

      node.announcedAddresses.len == 1
      node.announcedAddresses.contains(announcedEndpoint)

    await node.start()

    check:
      node.started
      # Underlying peer info listenAddrs has not changed
      node.switch.peerInfo.listenAddrs.len == 1
      node.switch.peerInfo.listenAddrs.contains(bindEndpoint)
      # Check that underlying peer info is updated with announced address
      node.switch.peerInfo.addrs.len == 1
      node.switch.peerInfo.addrs.contains(announcedEndpoint)

    await node.stop()

  asyncTest "Node can use dns4 in announced addresses":
    let
      nodeKey = generateSecp256k1Key()
      bindIp = parseIpAddress("0.0.0.0")
      bindPort = Port(61010)
      extIp = some(getPrimaryIPAddr())
      extPort = some(Port(61012))
      domainName = "example.com"
      expectedDns4Addr =
        MultiAddress.init("/dns4/" & domainName & "/tcp/" & $(extPort.get())).get()
      node = newTestWakuNode(
        nodeKey, bindIp, bindPort, extIp, extPort, dns4DomainName = some(domainName)
      )

    check:
      node.announcedAddresses.len == 1
      node.announcedAddresses.contains(expectedDns4Addr)

  asyncTest "Node uses dns4 resolved ip in announced addresses if no extIp is provided":
    let
      nodeKey = generateSecp256k1Key()
      bindIp = parseIpAddress("0.0.0.0")
      bindPort = Port(0)

      domainName = "status.im"
      node =
        newTestWakuNode(nodeKey, bindIp, bindPort, dns4DomainName = some(domainName))

    var ipStr = ""
    var enrIp = node.enr.tryGet("ip", array[4, byte])

    if enrIp.isSome():
      ipStr &= $ipv4(enrIp.get())

    # Check that the IP filled is the one received by the DNS lookup
    # As IPs may change, we check that it's not empty, not the 0 IP and not localhost
    check:
      ipStr.len() > 0
      not ipStr.contains("0.0.0.0")
      not ipStr.contains("127.0.0.1")

  asyncTest "Node creation fails when invalid dns4 address is provided":
    let
      nodeKey = generateSecp256k1Key()
      bindIp = parseIpAddress("0.0.0.0")
      bindPort = Port(0)

      inexistentDomain = "thisdomain.doesnot.exist"
      invalidDomain = ""
      expectedError = "Could not resolve IP from DNS: empty response"

    var inexistentDomainErr, invalidDomainErr: string = ""

    # Create node with inexistent domain
    try:
      let node = newTestWakuNode(
        nodeKey, bindIp, bindPort, dns4DomainName = some(inexistentDomain)
      )
    except Exception as e:
      inexistentDomainErr = e.msg

    # Create node with invalid domain
    try:
      let node =
        newTestWakuNode(nodeKey, bindIp, bindPort, dns4DomainName = some(invalidDomain))
    except Exception as e:
      invalidDomainErr = e.msg

    # Check that exceptions were raised in both cases
    check:
      inexistentDomainErr == expectedError
      invalidDomainErr == expectedError

  asyncTest "Agent string is set and advertised correctly":
    let
      # custom agent string
      expectedAgentString1 = "node1-agent-string"

      # bump when updating nim-libp2p
      expectedAgentString2 = "nim-libp2p/0.0.1"
    let
      # node with custom agent string
      nodeKey1 = generateSecp256k1Key()
      node1 = newTestWakuNode(
        nodeKey1,
        parseIpAddress("0.0.0.0"),
        Port(61014),
        agentString = some(expectedAgentString1),
      )

      # node with default agent string from libp2p
      nodeKey2 = generateSecp256k1Key()
      node2 = newTestWakuNode(nodeKey2, parseIpAddress("0.0.0.0"), Port(61016))

    await node1.start()
    (await node1.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"

    await node2.start()
    (await node2.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"

    await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])
    await node2.connectToNodes(@[node1.switch.peerInfo.toRemotePeerInfo()])

    let node1Agent =
      node2.switch.peerStore[AgentBook][node1.switch.peerInfo.toRemotePeerInfo().peerId]
    let node2Agent =
      node1.switch.peerStore[AgentBook][node2.switch.peerInfo.toRemotePeerInfo().peerId]

    check:
      node1Agent == expectedAgentString1
      node2Agent == expectedAgentString2

    await allFutures(node1.stop(), node2.stop())

  asyncTest "Custom multiaddresses are set and advertised correctly":
    let
      # custom multiaddress
      expectedMultiaddress1 = MultiAddress.init("/ip4/200.200.200.200/tcp/1234").get()

    # Note: this could have been done with a single node, but it is useful to
    # have two nodes to check that the multiaddress is advertised correctly
    let
      # node with custom multiaddress
      nodeKey1 = generateSecp256k1Key()
      node1 = newTestWakuNode(
        nodeKey1,
        parseIpAddress("0.0.0.0"),
        Port(61018),
        extMultiAddrs = @[expectedMultiaddress1],
      )

      # node with default multiaddress
      nodeKey2 = generateSecp256k1Key()
      node2 = newTestWakuNode(nodeKey2, parseIpAddress("0.0.0.0"), Port(61020))

    await node1.start()
    (await node1.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"

    await node2.start()
    (await node2.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"

    await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])
    await node2.connectToNodes(@[node1.switch.peerInfo.toRemotePeerInfo()])

    let node1MultiAddrs = node2.switch.peerStore[AddressBook][
      node1.switch.peerInfo.toRemotePeerInfo().peerId
    ]

    check:
      node1MultiAddrs.contains(expectedMultiaddress1)

    await allFutures(node1.stop(), node2.stop())
