{.used.}

import
  std/[nativesockets, net, sequtils],
  testutils/unittests,
  libp2p/[multiaddress, peerid],
  libp2p/crypto/crypto,
  eth/keys,
  eth/p2p/discoveryv5/enr,
  nimcrypto/utils,
  sqlite3_abi

import
  logos_delivery/waku/waku_core/peers,
  logos_delivery/waku/node/peer_manager/peer_store/waku_peer_storage

proc `==`(a, b: RemotePeerInfo): bool =
  let comparisons = @[
    a.peerId == b.peerId,
    a.addrs == b.addrs,
    a.enr == b.enr,
    a.protocols == b.protocols,
    a.agent == b.agent,
    a.protoVersion == b.protoVersion,
    a.publicKey == b.publicKey,
    a.connectedness == b.connectedness,
    a.disconnectTime == b.disconnectTime,
    a.origin == b.origin,
    a.direction == b.direction,
    a.lastFailedConn == b.lastFailedConn,
    a.numberFailedConn == b.numberFailedConn,
  ]

  allIt(comparisons, it == true)

suite "Protobuf Serialisation":
  let
    privateKeyStr =
      "08031279307702010104203E5B1FE9712E6C314942A750BD67485DE3C1EFE85B1BFB520AE8F9AE3DFA4A4CA00A06082A8648CE3D030107A14403420004DE3D300FA36AE0E8F5D530899D83ABAB44ABF3161F162A4BC901D8E6ECDA020E8B6D5F8DA30525E71D6851510C098E5C47C646A597FB4DCEC034E9F77C409E62"
    publicKeyStr =
      "0803125b3059301306072a8648ce3d020106082a8648ce3d03010703420004de3d300fa36ae0e8f5d530899d83abab44abf3161f162a4bc901d8e6ecda020e8b6d5f8da30525e71d6851510c098e5c47c646a597fb4dcec034e9f77c409e62"

  var remotePeerInfo {.threadvar.}: RemotePeerInfo

  setup:
    let
      port = Port(8080)
      ipAddress = IpAddress(family: IPv4, address_v4: [192, 168, 0, 1])
      multiAddress: MultiAddress =
        MultiAddress.init(ipAddress, IpTransportProtocol.tcpProtocol, port)
      encodedPeerIdStr = "16Uiu2HAmFccGe5iezmyRDQZuLPRP7FqpqXLjnocmMRk18pmTZs2j"

    var peerId: PeerID
    assert init(peerId, encodedPeerIdStr)

    let
      publicKey =
        crypto.PublicKey.init(utils.fromHex(publicKeyStr)).expect("public key")
      privateKey =
        crypto.PrivateKey.init(utils.fromHex(privateKeyStr)).expect("private key")

    remotePeerInfo = RemotePeerInfo.init(peerId, @[multiAddress])
    remotePeerInfo.publicKey = publicKey

  suite "encode":
    test "simple":
      # Given the expected bytes representation of a valid RemotePeerInfo.
      # Proto3 does not write `connectedness` (field 5) and `disconnectTime`
      # (field 6), because they have their default values.
      let expectedBuffer: seq[byte] = @[
        10, 39, 0, 37, 8, 2, 18, 33, 3, 43, 246, 238, 219, 109, 147, 79, 129, 40, 145,
        217, 209, 109, 105, 185, 186, 200, 180, 203, 72, 166, 220, 196, 232, 170, 74,
        141, 125, 255, 112, 238, 204, 18, 8, 4, 192, 168, 0, 1, 6, 31, 144, 34, 95, 8,
        3, 18, 91, 48, 89, 48, 19, 6, 7, 42, 134, 72, 206, 61, 2, 1, 6, 8, 42, 134, 72,
        206, 61, 3, 1, 7, 3, 66, 0, 4, 222, 61, 48, 15, 163, 106, 224, 232, 245, 213,
        48, 137, 157, 131, 171, 171, 68, 171, 243, 22, 31, 22, 42, 75, 201, 1, 216, 230,
        236, 218, 2, 14, 139, 109, 95, 141, 163, 5, 37, 231, 29, 104, 81, 81, 12, 9,
        142, 92, 71, 198, 70, 165, 151, 251, 77, 206, 192, 52, 233, 247, 124, 64, 158,
        98,
      ]

      # When converting a valid RemotePeerInfo to bytes
      let encodedRemotePeerInfo = encode(remotePeerInfo).get()

      # Then the encoded RemotePeerInfo should be equal to the expected bytes,
      # and it decodes to the original RemotePeerInfo
      check:
        encodedRemotePeerInfo == expectedBuffer
        RemotePeerInfo.decode(encodedRemotePeerInfo).get() == remotePeerInfo

    test "a peer without a public key is not encoded":
      # A peer from an ENR or from a multiaddress has no key yet.
      let peer = RemotePeerInfo.init(remotePeerInfo.peerId, remotePeerInfo.addrs)
      check peer.encode().isErr()

  suite "decode":
    test "simple":
      # Given the bytes representation of a valid RemotePeerInfo, as the
      # `minprotobuf` codec stored it before the change to proto3. It also
      # has the fields 5 and 6 with their default values.
      let buffer: seq[byte] = @[
        10, 39, 0, 37, 8, 2, 18, 33, 3, 43, 246, 238, 219, 109, 147, 79, 129, 40, 145,
        217, 209, 109, 105, 185, 186, 200, 180, 203, 72, 166, 220, 196, 232, 170, 74,
        141, 125, 255, 112, 238, 204, 18, 8, 4, 192, 168, 0, 1, 6, 31, 144, 34, 95, 8,
        3, 18, 91, 48, 89, 48, 19, 6, 7, 42, 134, 72, 206, 61, 2, 1, 6, 8, 42, 134, 72,
        206, 61, 3, 1, 7, 3, 66, 0, 4, 222, 61, 48, 15, 163, 106, 224, 232, 245, 213,
        48, 137, 157, 131, 171, 171, 68, 171, 243, 22, 31, 22, 42, 75, 201, 1, 216, 230,
        236, 218, 2, 14, 139, 109, 95, 141, 163, 5, 37, 231, 29, 104, 81, 81, 12, 9,
        142, 92, 71, 198, 70, 165, 151, 251, 77, 206, 192, 52, 233, 247, 124, 64, 158,
        98, 40, 0, 48, 0,
      ]

      # When converting a valid buffer to RemotePeerInfo
      let decodedRemotePeerInfo = RemotePeerInfo.decode(buffer).get()

      # Then the decoded RemotePeerInfo should be equal to the original RemotePeerInfo
      check:
        decodedRemotePeerInfo == remotePeerInfo

suite "WakuPeerStorage - load":
  test "a stored peer that does not decode is skipped and kept, and the other peers load":
    # Three rows that the `minprotobuf` codec stored, in the order of their
    # peer ids. Each row has the protocol "/vac/waku/relay/2.0.0". The row in
    # the middle also has the protocol bytes 2f 78 ff, which are not valid
    # UTF-8. An older version can store such a row, and the proto3 codec
    # refuses it.
    const rows = [
      (
        "002508021221024d4b6cd1361032ca9bd2aeb9d900aa4d45d9ead80ac9423374" &
          "c451a7254d0766",
        "0a27002508021221024d4b6cd1361032ca9bd2aeb9d900aa4d45d9ead80ac942" &
          "3374c451a7254d0766120804c0a80002061f901a152f7661632f77616b752f72" &
          "656c61792f322e302e30222508021221024d4b6cd1361032ca9bd2aeb9d900aa" &
          "4d45d9ead80ac9423374c451a7254d076628003000",
      ),
      (
        "00250802122102531fe6068134503d2723133227c867ac8fa6c83c537e9a44c3" &
          "c5bdbdcb1fe337",
        "0a2700250802122102531fe6068134503d2723133227c867ac8fa6c83c537e9a" &
          "44c3c5bdbdcb1fe337120804c0a80003061f901a152f7661632f77616b752f72" &
          "656c61792f322e302e301a032f78ff22250802122102531fe6068134503d2723" &
          "133227c867ac8fa6c83c537e9a44c3c5bdbdcb1fe33728003000",
      ),
      (
        "002508021221031b84c5567b126440995d3ed5aaba0565d71e1834604819ff9c" &
          "17f5e9d5dd078f",
        "0a27002508021221031b84c5567b126440995d3ed5aaba0565d71e1834604819" &
          "ff9c17f5e9d5dd078f120804c0a80001061f901a152f7661632f77616b752f72" &
          "656c61792f322e302e30222508021221031b84c5567b126440995d3ed5aaba05" &
          "65d71e1834604819ff9c17f5e9d5dd078f28003000",
      ),
    ]
    let
      database = SqliteDatabase.new(":memory:").tryGet()
      storage = WakuPeerStorage.new(database).tryGet()
    defer:
      storage.close()
    let insert = database
      .prepareStmt(
        "INSERT INTO Peer (peerId, storedInfo) VALUES (?, ?);",
        (seq[byte], seq[byte]),
        void,
      )
      .tryGet()
    for (id, info) in rows:
      check insert.exec((utils.fromHex(id), utils.fromHex(info))).isOk()
    insert.dispose()

    var loaded: seq[PeerId]
    proc onPeer(peer: RemotePeerInfo) =
      loaded.add(peer.peerId)

    let expected = @[rows[0][0], rows[2][0]].mapIt(PeerId.init(utils.fromHex(it)).get())
    var rowCount = 0
    proc onRow(s: ptr sqlite3_stmt) =
      inc rowCount

    check:
      storage.getAll(onPeer).isOk()
      loaded == expected
      database.query("SELECT peerId FROM Peer", onRow).isOk()
      rowCount == 3
