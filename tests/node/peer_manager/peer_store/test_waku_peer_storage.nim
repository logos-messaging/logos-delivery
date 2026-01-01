import
  std/[nativesockets, options, sequtils],
  testutils/unittests,
  libp2p/[multiaddress, peerid],
  libp2p/crypto/crypto,
  eth/keys,
  eth/enr/enr,
  nimcrypto/utils

import waku/waku_core/peers, waku/node/peer_manager/peer_store/waku_peer_storage

proc `==`(a, b: RemotePeerInfo): bool =
  let comparisons =
    @[
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
      # Given the expected bytes representation of a valid RemotePeerInfo
      let expectedBuffer: seq[byte] =
        @[
          10, 39, 0, 37, 8, 2, 18, 33, 3, 43, 246, 238, 219, 109, 147, 79, 129, 40, 145,
          217, 209, 109, 105, 185, 186, 200, 180, 203, 72, 166, 220, 196, 232, 170, 74,
          141, 125, 255, 112, 238, 204, 18, 8, 4, 192, 168, 0, 1, 6, 31, 144, 34, 95, 8,
          3, 18, 91, 48, 89, 48, 19, 6, 7, 42, 134, 72, 206, 61, 2, 1, 6, 8, 42, 134,
          72, 206, 61, 3, 1, 7, 3, 66, 0, 4, 222, 61, 48, 15, 163, 106, 224, 232, 245,
          213, 48, 137, 157, 131, 171, 171, 68, 171, 243, 22, 31, 22, 42, 75, 201, 1,
          216, 230, 236, 218, 2, 14, 139, 109, 95, 141, 163, 5, 37, 231, 29, 104, 81,
          81, 12, 9, 142, 92, 71, 198, 70, 165, 151, 251, 77, 206, 192, 52, 233, 247,
          124, 64, 158, 98, 40, 0, 48, 0,
        ]

      # When converting a valid RemotePeerInfo to a ProtoBuffer
      let encodedRemotePeerInfo = encode(remotePeerInfo).get()

      # Then the encoded RemotePeerInfo should be equal to the expected bytes
      check:
        encodedRemotePeerInfo.buffer == expectedBuffer
        encodedRemotePeerInfo.offset == 152
        encodedRemotePeerInfo.length == 0
        encodedRemotePeerInfo.maxSize == 4194304

  suite "decode":
    test "simple":
      # Given the bytes representation of a valid RemotePeerInfo
      let buffer: seq[byte] =
        @[
          10, 39, 0, 37, 8, 2, 18, 33, 3, 43, 246, 238, 219, 109, 147, 79, 129, 40, 145,
          217, 209, 109, 105, 185, 186, 200, 180, 203, 72, 166, 220, 196, 232, 170, 74,
          141, 125, 255, 112, 238, 204, 18, 8, 4, 192, 168, 0, 1, 6, 31, 144, 34, 95, 8,
          3, 18, 91, 48, 89, 48, 19, 6, 7, 42, 134, 72, 206, 61, 2, 1, 6, 8, 42, 134,
          72, 206, 61, 3, 1, 7, 3, 66, 0, 4, 222, 61, 48, 15, 163, 106, 224, 232, 245,
          213, 48, 137, 157, 131, 171, 171, 68, 171, 243, 22, 31, 22, 42, 75, 201, 1,
          216, 230, 236, 218, 2, 14, 139, 109, 95, 141, 163, 5, 37, 231, 29, 104, 81,
          81, 12, 9, 142, 92, 71, 198, 70, 165, 151, 251, 77, 206, 192, 52, 233, 247,
          124, 64, 158, 98, 40, 0, 48, 0,
        ]

      # When converting a valid buffer to RemotePeerInfo
      let decodedRemotePeerInfo = RemotePeerInfo.decode(buffer).get()

      # Then the decoded RemotePeerInfo should be equal to the original RemotePeerInfo
      check:
        decodedRemotePeerInfo == remotePeerInfo
