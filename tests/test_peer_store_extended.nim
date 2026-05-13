{.used.}

import
  std/[sequtils, times],
  chronos,
  libp2p/crypto/crypto,
  libp2p/peerid,
  libp2p/peerstore,
  libp2p/multiaddress,
  testutils/unittests
import
  waku/
    [node/peer_manager/peer_manager, node/peer_manager/waku_peer_store, waku_core/peers],
  ./testlib/wakucore

suite "Extended nim-libp2p Peer Store":
  # Valid peerId missing the last digit. Useful for creating new peerIds
  # basePeerId & "1"
  # basePeerId & "2"
  let basePeerId = "QmeuZJbXrszW2jdT7GdduSjQskPU3S7vvGWKtKgDfkDvW"

  setup:
    # Setup a nim-libp2p peerstore with some peers
    let peerStore = PeerStore.new(nil, capacity = 50)
    var p1, p2, p3, p4, p5, p6: PeerId

    # create five peers basePeerId + [1-5]
    require p1.init(basePeerId & "1")
    require p2.init(basePeerId & "2")
    require p3.init(basePeerId & "3")
    require p4.init(basePeerId & "4")
    require p5.init(basePeerId & "5")

    # peer6 is not part of the peerstore
    require p6.init(basePeerId & "6")

    # Peer1: Connected
    peerStore.addPeer(
      RemotePeerInfo.init(
        peerId = p1,
        addrs = @[MultiAddress.init("/ip4/127.0.0.1/tcp/1").tryGet()],
        protocols = @["/vac/waku/relay/2.0.0-beta1", "/vac/waku/store/2.0.0"],
        publicKey = generateEcdsaKeyPair().pubkey,
        agent = "nwaku",
        protoVersion = "protoVersion1",
        connectedness = Connected,
        disconnectTime = 0,
        origin = Discv5,
        direction = Inbound,
        lastFailedConn = Moment.init(1001, Second),
        numberFailedConn = 1,
      )
    )

    # Peer2: Connected
    peerStore.addPeer(
      RemotePeerInfo.init(
        peerId = p2,
        addrs = @[MultiAddress.init("/ip4/127.0.0.1/tcp/2").tryGet()],
        protocols = @["/vac/waku/relay/2.0.0", "/vac/waku/store/2.0.0"],
        publicKey = generateEcdsaKeyPair().pubkey,
        agent = "nwaku",
        protoVersion = "protoVersion2",
        connectedness = Connected,
        disconnectTime = 0,
        origin = Discv5,
        direction = Inbound,
        lastFailedConn = Moment.init(1002, Second),
        numberFailedConn = 2,
      )
    )

    # Peer3: Connected
    peerStore.addPeer(
      RemotePeerInfo.init(
        peerId = p3,
        addrs = @[MultiAddress.init("/ip4/127.0.0.1/tcp/3").tryGet()],
        protocols = @["/vac/waku/lightpush/2.0.0", "/vac/waku/store/2.0.0-beta1"],
        publicKey = generateEcdsaKeyPair().pubkey,
        agent = "gowaku",
        protoVersion = "protoVersion3",
        connectedness = Connected,
        disconnectTime = 0,
        origin = Discv5,
        direction = Inbound,
        lastFailedConn = Moment.init(1003, Second),
        numberFailedConn = 3,
      )
    )

    # Peer4: Added but never connected
    peerStore.addPeer(
      RemotePeerInfo.init(
        peerId = p4,
        addrs = @[MultiAddress.init("/ip4/127.0.0.1/tcp/4").tryGet()],
        protocols = @[],
        publicKey = generateEcdsaKeyPair().pubkey,
        agent = "",
        protoVersion = "",
        connectedness = NotConnected,
        disconnectTime = 0,
        origin = Discv5,
        direction = Inbound,
        lastFailedConn = Moment.init(1004, Second),
        numberFailedConn = 4,
      )
    )

    # Peer5: Connected
    peerStore.addPeer(
      RemotePeerInfo.init(
        peerId = p5,
        addrs = @[MultiAddress.init("/ip4/127.0.0.1/tcp/5").tryGet()],
        protocols = @["/vac/waku/swap/2.0.0", "/vac/waku/store/2.0.0-beta2"],
        publicKey = generateEcdsaKeyPair().pubkey,
        agent = "gowaku",
        protoVersion = "protoVersion5",
        connectedness = CanConnect,
        disconnectTime = 1000,
        origin = Discv5,
        direction = Outbound,
        lastFailedConn = Moment.init(1005, Second),
        numberFailedConn = 5,
      )
    )

  test "get() returns the correct StoredInfo for a given PeerId":
    # When
    let peer1 = peerStore.getPeer(p1)
    let peer6 = peerStore.getPeer(p6)

    # Then
    check:
      # regression on nim-libp2p fields
      peer1.peerId == p1
      peer1.addrs == @[MultiAddress.init("/ip4/127.0.0.1/tcp/1").tryGet()]
      peer1.protocols == @["/vac/waku/relay/2.0.0-beta1", "/vac/waku/store/2.0.0"]
      peer1.agent == "nwaku"
      peer1.protoVersion == "protoVersion1"

      # our extended fields
      peer1.connectedness == Connected
      peer1.disconnectTime == 0
      peer1.origin == Discv5
      peer1.numberFailedConn == 1
      peer1.lastFailedConn == Moment.init(1001, Second)

    check:
      # fields are empty, not part of the peerstore
      peer6.peerId == p6
      peer6.addrs.len == 0
      peer6.protocols.len == 0
      peer6.agent == default(string)
      peer6.protoVersion == default(string)
      peer6.connectedness == default(Connectedness)
      peer6.disconnectTime == default(int)
      peer6.origin == default(PeerOrigin)
      peer6.numberFailedConn == default(int)
      peer6.lastFailedConn == default(Moment)

  test "peers() returns all StoredInfo of the PeerStore":
    # When
    let allPeers = peerStore.peers()

    # Then
    check:
      allPeers.len == 5
      allPeers.anyIt(it.peerId == p1)
      allPeers.anyIt(it.peerId == p2)
      allPeers.anyIt(it.peerId == p3)
      allPeers.anyIt(it.peerId == p4)
      allPeers.anyIt(it.peerId == p5)

    let p3 = allPeers.filterIt(it.peerId == p3)[0]

    check:
      # regression on nim-libp2p fields
      p3.addrs == @[MultiAddress.init("/ip4/127.0.0.1/tcp/3").tryGet()]
      p3.protocols == @["/vac/waku/lightpush/2.0.0", "/vac/waku/store/2.0.0-beta1"]
      p3.agent == "gowaku"
      p3.protoVersion == "protoVersion3"

      # our extended fields
      p3.connectedness == Connected
      p3.disconnectTime == 0
      p3.origin == Discv5
      p3.numberFailedConn == 3
      p3.lastFailedConn == Moment.init(1003, Second)

  test "peers() returns all StoredInfo matching a specific protocol":
    # When
    let storePeers = peerStore.peers("/vac/waku/store/2.0.0")
    let lpPeers = peerStore.peers("/vac/waku/lightpush/2.0.0")

    # Then
    check:
      # Only p1 and p2 support that protocol
      storePeers.len == 2
      storePeers.anyIt(it.peerId == p1)
      storePeers.anyIt(it.peerId == p2)

    check:
      # Only p3 supports that protocol
      lpPeers.len == 1
      lpPeers.anyIt(it.peerId == p3)
      lpPeers[0].protocols ==
        @["/vac/waku/lightpush/2.0.0", "/vac/waku/store/2.0.0-beta1"]

  test "peers() returns all StoredInfo matching a given protocolMatcher":
    # When
    let pMatcherStorePeers = peerStore.peers(protocolMatcher("/vac/waku/store/2.0.0"))
    let pMatcherSwapPeers = peerStore.peers(protocolMatcher("/vac/waku/swap/2.0.0"))

    # Then
    check:
      # peers: 1,2,3,5 match /vac/waku/store/2.0.0/xxx
      pMatcherStorePeers.len == 4
      pMatcherStorePeers.anyIt(it.peerId == p1)
      pMatcherStorePeers.anyIt(it.peerId == p2)
      pMatcherStorePeers.anyIt(it.peerId == p3)
      pMatcherStorePeers.anyIt(it.peerId == p5)

    check:
      pMatcherStorePeers.filterIt(it.peerId == p1)[0].protocols ==
        @["/vac/waku/relay/2.0.0-beta1", "/vac/waku/store/2.0.0"]
      pMatcherStorePeers.filterIt(it.peerId == p2)[0].protocols ==
        @["/vac/waku/relay/2.0.0", "/vac/waku/store/2.0.0"]
      pMatcherStorePeers.filterIt(it.peerId == p3)[0].protocols ==
        @["/vac/waku/lightpush/2.0.0", "/vac/waku/store/2.0.0-beta1"]
      pMatcherStorePeers.filterIt(it.peerId == p5)[0].protocols ==
        @["/vac/waku/swap/2.0.0", "/vac/waku/store/2.0.0-beta2"]

    check:
      pMatcherSwapPeers.len == 1
      pMatcherSwapPeers.anyIt(it.peerId == p5)
      pMatcherSwapPeers[0].protocols ==
        @["/vac/waku/swap/2.0.0", "/vac/waku/store/2.0.0-beta2"]

  test "toRemotePeerInfo() converts a StoredInfo to a RemotePeerInfo":
    # Given
    let peer1 = peerStore.getPeer(p1)

    # Then
    check:
      peer1.peerId == p1
      peer1.addrs == @[MultiAddress.init("/ip4/127.0.0.1/tcp/1").tryGet()]
      peer1.protocols == @["/vac/waku/relay/2.0.0-beta1", "/vac/waku/store/2.0.0"]

  test "connectedness() returns the connection status of a given PeerId":
    check:
      # peers tracked in the peerstore
      peerStore.connectedness(p1) == Connected
      peerStore.connectedness(p2) == Connected
      peerStore.connectedness(p3) == Connected
      peerStore.connectedness(p4) == NotConnected
      peerStore.connectedness(p5) == CanConnect

      # peer not tracked in the peerstore
      peerStore.connectedness(p6) == NotConnected

  test "hasPeer() returns true if the peer supports a given protocol":
    check:
      peerStore.hasPeer(p1, "/vac/waku/relay/2.0.0-beta1")
      peerStore.hasPeer(p1, "/vac/waku/store/2.0.0")
      not peerStore.hasPeer(p1, "it-does-not-contain-this-protocol")

      peerStore.hasPeer(p2, "/vac/waku/relay/2.0.0")
      peerStore.hasPeer(p2, "/vac/waku/store/2.0.0")

      peerStore.hasPeer(p3, "/vac/waku/lightpush/2.0.0")
      peerStore.hasPeer(p3, "/vac/waku/store/2.0.0-beta1")

      # we have no knowledge of p4 supported protocols
      not peerStore.hasPeer(p4, "/vac/waku/lightpush/2.0.0")

      peerStore.hasPeer(p5, "/vac/waku/swap/2.0.0")
      peerStore.hasPeer(p5, "/vac/waku/store/2.0.0-beta2")
      not peerStore.hasPeer(p5, "another-protocol-not-contained")

      # peer 6 is not in the PeerStore
      not peerStore.hasPeer(p6, "/vac/waku/lightpush/2.0.0")

  test "hasPeers() returns true if any peer in the PeerStore supports a given protocol":
    # Match specific protocols
    check:
      peerStore.hasPeers("/vac/waku/relay/2.0.0-beta1")
      peerStore.hasPeers("/vac/waku/store/2.0.0")
      peerStore.hasPeers("/vac/waku/lightpush/2.0.0")
      not peerStore.hasPeers("/vac/waku/does-not-exist/2.0.0")

    # Match protocolMatcher protocols
    check:
      peerStore.hasPeers(protocolMatcher("/vac/waku/store/2.0.0"))
      not peerStore.hasPeers(protocolMatcher("/vac/waku/does-not-exist/2.0.0"))

  test "getPeersByDirection()":
    # When
    let inPeers = peerStore.getPeersByDirection(Inbound)
    let outPeers = peerStore.getPeersByDirection(Outbound)

    # Then
    check:
      inPeers.len == 4
      outPeers.len == 1

  test "getDisconnectedPeers()":
    # When
    let disconnedtedPeers = peerStore.getDisconnectedPeers()

    # Then
    check:
      disconnedtedPeers.len == 2
      disconnedtedPeers.anyIt(it.peerId == p4)
      disconnedtedPeers.anyIt(it.peerId == p5)
      not disconnedtedPeers.anyIt(it.connectedness == Connected)

  test "del() successfully deletes waku custom books":
    # Given
    let peerStore = PeerStore.new(nil, capacity = 5)
    var p1: PeerId
    require p1.init("QmeuZJbXrszW2jdT7GdduSjQskPU3S7vvGWKtKgDfkDvW1")

    let remotePeer = RemotePeerInfo.init(
      peerId = p1,
      addrs = @[MultiAddress.init("/ip4/127.0.0.1/tcp/1").tryGet()],
      protocols = @["proto"],
      publicKey = generateEcdsaKeyPair().pubkey,
      agent = "agent",
      protoVersion = "version",
      lastFailedConn = Moment.init(getTime().toUnix, Second),
      numberFailedConn = 1,
      connectedness = Connected,
      disconnectTime = 0,
      origin = Discv5,
      direction = Inbound,
    )

    peerStore.addPeer(remotePeer)

    # When
    peerStore.delete(p1)

    # Then
    check:
      peerStore[AddressBook][p1] == newSeq[MultiAddress](0)
      peerStore[ProtoBook][p1] == newSeq[string](0)
      peerStore[KeyBook][p1] == default(PublicKey)
      peerStore[AgentBook][p1] == ""
      peerStore[ProtoVersionBook][p1] == ""
      peerStore[LastFailedConnBook][p1] == default(Moment)
      peerStore[NumberFailedConnBook][p1] == 0
      peerStore[ConnectionBook][p1] == default(Connectedness)
      peerStore[DisconnectBook][p1] == 0
      peerStore[SourceBook][p1] == default(PeerOrigin)
      peerStore[DirectionBook][p1] == default(PeerDirection)
