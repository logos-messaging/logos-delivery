{.used.}

import
  std/[sequtils, times, random],
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
      peerStore[GriefBook][p1] == default(GriefData)

  suite "Extended nim-libp2p Peer Store: grief scores":
    # These tests mock the clock and work better as a separate suite
    var peerStore: PeerStore
    var p1, p2, p3: PeerId

    setup:
      peerStore = PeerStore.new(nil, capacity = 50)
      require p1.init(basePeerId & "1")
      require p2.init(basePeerId & "2")
      require p3.init(basePeerId & "3")

    # Shorthand: one cooldown interval
    let interval = GriefCooldownInterval

    test "new peer has grief score 0":
      check peerStore.getGriefScore(p1) == 0

    test "griefPeer increases score":
      let t0 = Moment.init(1000, Minute)

      peerStore.griefPeer(p1, 5, t0)
      check peerStore.getGriefScore(p1, t0) == 5

    test "griefPeer accumulates":
      let t0 = Moment.init(1000, Minute)

      peerStore.griefPeer(p1, 3, t0)
      peerStore.griefPeer(p1, 2, t0)
      check peerStore.getGriefScore(p1, t0) == 5

    test "grief cools down by 1 point per interval":
      let t0 = Moment.init(1000, Minute)

      peerStore.griefPeer(p1, 5, t0)

      check peerStore.getGriefScore(p1, t0) == 5
      check peerStore.getGriefScore(p1, t0 + interval * 1) == 4
      check peerStore.getGriefScore(p1, t0 + interval * 2) == 3
      check peerStore.getGriefScore(p1, t0 + interval * 3) == 2
      check peerStore.getGriefScore(p1, t0 + interval * 4) == 1
      check peerStore.getGriefScore(p1, t0 + interval * 5) == 0

    test "grief floors at 0":
      let t0 = Moment.init(1000, Minute)

      peerStore.griefPeer(p1, 3, t0)

      # Well past full cooldown, should be 0
      check peerStore.getGriefScore(p1, t0 + interval * 10) == 0

    test "cooldown preserves remainder":
      let t0 = Moment.init(1000, Minute)
      # Half an interval past 2 full intervals
      let tHalf = t0 + interval * 2 + interval div 2
      # Complete the 3rd interval
      let t3 = t0 + interval * 3

      peerStore.griefPeer(p1, 5, t0)

      # After 2.5 intervals, score should be 3
      check peerStore.getGriefScore(p1, tHalf) == 3

      # After completing the 3rd interval, score should be 2
      check peerStore.getGriefScore(p1, t3) == 2

    test "grief after full cooldown restarts cooldown time":
      let t0 = Moment.init(1000, Minute)

      peerStore.griefPeer(p1, 2, t0)

      # Fully cool down
      check peerStore.getGriefScore(p1, t0 + interval * 5) == 0

      # Grief again
      let t1 = t0 + interval * 5
      peerStore.griefPeer(p1, 3, t1)
      check peerStore.getGriefScore(p1, t1) == 3

      # 1 interval after second grief
      check peerStore.getGriefScore(p1, t1 + interval) == 2

    test "independent grief scores per peer":
      let t0 = Moment.init(1000, Minute)

      peerStore.griefPeer(p1, 10, t0)
      peerStore.griefPeer(p2, 3, t0)

      check peerStore.getGriefScore(p1, t0 + interval * 2) == 8
      check peerStore.getGriefScore(p2, t0 + interval * 2) == 1
      check peerStore.getGriefScore(p3, t0 + interval * 2) == 0

    test "grief with default amount is 1":
      let t0 = Moment.init(1000, Minute)

      peerStore.griefPeer(p1, now = t0)
      check peerStore.getGriefScore(p1, t0) == 1

    test "griefPeer with zero or negative amount is ignored":
      let t0 = Moment.init(1000, Minute)

      peerStore.griefPeer(p1, 5, t0)
      peerStore.griefPeer(p1, 0, t0)
      peerStore.griefPeer(p1, -3, t0)
      check peerStore.getGriefScore(p1, t0) == 5

    test "grief added during partial cooldown does not reset cooldown time":
      let t0 = Moment.init(1000, Minute)
      let tHalf = t0 + interval * 2 + interval div 2
      let t3 = t0 + interval * 3
      let t4 = t0 + interval * 4

      peerStore.griefPeer(p1, 5, t0)

      # At 2.5 intervals: 2 consumed, score 3, half-interval remainder
      check peerStore.getGriefScore(p1, tHalf) == 3

      # Add more grief — cooldown time should NOT reset, remainder preserved
      peerStore.griefPeer(p1, 4, tHalf)
      check peerStore.getGriefScore(p1, tHalf) == 7

      # Remainder completes another interval
      check peerStore.getGriefScore(p1, t3) == 6

      # And one more full interval
      check peerStore.getGriefScore(p1, t4) == 5

    test "multiple reads without time change are idempotent":
      let t0 = Moment.init(1000, Minute)

      peerStore.griefPeer(p1, 10, t0)

      check peerStore.getGriefScore(p1, t0 + interval * 3) == 7
      check peerStore.getGriefScore(p1, t0 + interval * 3) == 7
      check peerStore.getGriefScore(p1, t0 + interval * 3) == 7

    test "interleaved grief and cooldown across multiple peers":
      let t0 = Moment.init(1000, Minute)

      # Stagger grief: p1 at t0, p2 at t0+1interval, p3 at t0+2interval
      peerStore.griefPeer(p1, 6, t0)
      peerStore.griefPeer(p2, 4, t0 + interval)
      peerStore.griefPeer(p3, 2, t0 + interval * 2)

      # At t0+3*interval: p1 lost 3, p2 lost 2, p3 lost 1
      check peerStore.getGriefScore(p1, t0 + interval * 3) == 3
      check peerStore.getGriefScore(p2, t0 + interval * 3) == 2
      check peerStore.getGriefScore(p3, t0 + interval * 3) == 1

      # Grief p2 again at t0+3I
      peerStore.griefPeer(p2, 10, t0 + interval * 3)

      # At t0+5*interval: p1 lost 5 total, p2 lost 2 more since re-grief, p3 floored at 0
      check peerStore.getGriefScore(p1, t0 + interval * 5) == 1
      check peerStore.getGriefScore(p2, t0 + interval * 5) == 10
      check peerStore.getGriefScore(p3, t0 + interval * 5) == 0

  suite "Extended nim-libp2p Peer Store: grief-based peer selection":
    # Tests for sortByGriefScore via selectPeers
    const testProto = "/test/grief/1.0.0"

    proc makePeer(port: int): RemotePeerInfo =
      let key = generateSecp256k1Key()
      RemotePeerInfo.init(
        peerId = PeerId.init(key.getPublicKey().tryGet()).tryGet(),
        addrs = @[MultiAddress.init("/ip4/127.0.0.1/tcp/" & $port).tryGet()],
        protocols = @[testProto],
      )

    test "all peers at grief 0 returns all peers (shuffled)":
      let switch = newTestSwitch()
      let pm = PeerManager.new(switch)
      let peerStore = switch.peerStore
      let peers = (1..5).mapIt(makePeer(it + 10000))
      for p in peers:
        peerStore.addPeer(p)

      let selected = pm.selectPeers(testProto)
      check selected.len == 5

    test "lower grief peers come before higher grief peers":
      let switch = newTestSwitch()
      let pm = PeerManager.new(switch)
      let peerStore = switch.peerStore
      let pA = makePeer(20001)
      let pB = makePeer(20002)
      let pC = makePeer(20003)
      peerStore.addPeer(pA)
      peerStore.addPeer(pB)
      peerStore.addPeer(pC)

      # pA: grief 0 (bucket 0), pB: grief 5 (bucket 1), pC: grief 15 (bucket 3)
      peerStore.griefPeer(pB.peerId, 5)
      peerStore.griefPeer(pC.peerId, 15)

      # Run multiple times to account for shuffle within buckets
      for i in 0 ..< 20:
        let selected = pm.selectPeers(testProto)
        check selected.len == 3
        # pA (bucket 0) must always be first
        check selected[0].peerId == pA.peerId
        # pB (bucket 1) must always come before pC (bucket 3)
        check selected[1].peerId == pB.peerId
        check selected[2].peerId == pC.peerId

    test "peers within same bucket are interchangeable":
      let switch = newTestSwitch()
      let pm = PeerManager.new(switch)
      let peerStore = switch.peerStore
      let pA = makePeer(30001)
      let pB = makePeer(30002)
      peerStore.addPeer(pA)
      peerStore.addPeer(pB)

      # Both within bucket 0 (scores 1 and 4, both div 5 == 0)
      peerStore.griefPeer(pA.peerId, 1)
      peerStore.griefPeer(pB.peerId, 4)

      var sawAFirst = false
      var sawBFirst = false
      for i in 0 ..< 50:
        let selected = pm.selectPeers(testProto)
        check selected.len == 2
        if selected[0].peerId == pA.peerId:
          sawAFirst = true
        else:
          sawBFirst = true

      # Both orderings should appear since they're in the same bucket
      check sawAFirst
      check sawBFirst

    test "peers in different buckets never swap order":
      let switch = newTestSwitch()
      let pm = PeerManager.new(switch)
      let peerStore = switch.peerStore
      let pLow = makePeer(40001)
      let pHigh = makePeer(40002)
      peerStore.addPeer(pLow)
      peerStore.addPeer(pHigh)

      # pLow in bucket 0 (score 1), pHigh in bucket 1 (score 5)
      peerStore.griefPeer(pLow.peerId, 1)
      peerStore.griefPeer(pHigh.peerId, 5)

      for i in 0 ..< 30:
        let selected = pm.selectPeers(testProto)
        check selected.len == 2
        check selected[0].peerId == pLow.peerId
        check selected[1].peerId == pHigh.peerId

    test "zero-grief peers always come before grieved peers":
      let switch = newTestSwitch()
      let pm = PeerManager.new(switch)
      let peerStore = switch.peerStore
      let pClean1 = makePeer(50001)
      let pClean2 = makePeer(50002)
      let pGrieved = makePeer(50003)
      peerStore.addPeer(pClean1)
      peerStore.addPeer(pClean2)
      peerStore.addPeer(pGrieved)

      peerStore.griefPeer(pGrieved.peerId, 6)

      for i in 0 ..< 20:
        let selected = pm.selectPeers(testProto)
        check selected.len == 3
        # Grieved peer (bucket 1) must be last; clean peers (bucket 0) first
        check selected[2].peerId == pGrieved.peerId

    test "peers beyond MaxGriefBucket are excluded from selection":
      let switch = newTestSwitch()
      let pm = PeerManager.new(switch)
      let peerStore = switch.peerStore
      let pGood = makePeer(60001)
      let pBad = makePeer(60002)
      peerStore.addPeer(pGood)
      peerStore.addPeer(pBad)

      # pBad in bucket 4 (score 20, 20 div 5 = 4 > MaxGriefBucket)
      peerStore.griefPeer(pBad.peerId, 20)

      let selected = pm.selectPeers(testProto)
      check selected.len == 1
      check selected[0].peerId == pGood.peerId
