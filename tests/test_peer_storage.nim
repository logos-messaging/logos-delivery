{.used.}

import std/options, testutils/unittests, eth/enr/enr, libp2p/crypto/crypto
import
  waku/[
    common/databases/db_sqlite,
    node/peer_manager/peer_manager,
    node/peer_manager/peer_store/waku_peer_storage,
    waku_enr,
  ],
  ./testlib/wakucore

suite "Peer Storage":
  test "Store, replace and retrieve from persistent peer storage":
    let
      database = SqliteDatabase.new(":memory:").tryGet()
      storage = WakuPeerStorage.new(database)[]

      # Test Peer
      peerLoc = MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet()
      peerKey = generateSecp256k1Key()
      peer = PeerInfo.new(peerKey, @[peerLoc])
      peerProto = "/waku/2/default-waku/codec"
      connectedness = Connectedness.CanConnect
      disconn = 999999
      pubsubTopics = @["/waku/2/rs/2/0", "/waku/2/rs/2/1"]

    # Create ENR
    var enrBuilder = EnrBuilder.init(peerKey)
    enrBuilder.withShardedTopics(pubsubTopics).expect("Valid topics")
    let record = enrBuilder.build().expect("Valid record")

    let stored = RemotePeerInfo(
      peerId: peer.peerId,
      addrs: @[peerLoc],
      enr: some(record),
      protocols: @[peerProto],
      publicKey: peerKey.getPublicKey().tryGet(),
      connectedness: connectedness,
      disconnectTime: disconn,
    )

    defer:
      storage.close()

    # Test insert and retrieve

    require storage.put(stored).isOk

    var responseCount = 0

    # Fetched variable from callback
    var resStoredInfo: RemotePeerInfo

    proc data(storedInfo: RemotePeerInfo) =
      responseCount += 1
      resStoredInfo = storedInfo

    let res = storage.getAll(data)

    check:
      res.isErr == false
      responseCount == 1
      resStoredInfo.peerId == peer.peerId
      resStoredInfo.addrs == @[peerLoc]
      resStoredInfo.protocols == @[peerProto]
      resStoredInfo.publicKey == peerKey.getPublicKey().tryGet()
      resStoredInfo.connectedness == connectedness
      resStoredInfo.disconnectTime == disconn

    assert resStoredInfo.enr.isSome(), "The ENR info wasn't properly stored"
    check:
      resStoredInfo.enr.get() == record

    # Test replace and retrieve (update an existing entry)
    stored.connectedness = CannotConnect
    stored.disconnectTime = disconn + 10
    stored.enr = none(Record)
    require storage.put(stored).isOk

    responseCount = 0
    proc replacedData(storedInfo: RemotePeerInfo) =
      responseCount += 1
      resStoredInfo = storedInfo

    let repRes = storage.getAll(replacedData)

    check:
      repRes.isErr == false
      responseCount == 1
      resStoredInfo.peerId == peer.peerId
      resStoredInfo.addrs == @[peerLoc]
      resStoredInfo.protocols == @[peerProto]
      resStoredInfo.publicKey == peerKey.getPublicKey().tryGet()
      resStoredInfo.connectedness == Connectedness.CannotConnect
      resStoredInfo.disconnectTime == disconn + 10
      resStoredInfo.enr.isNone()
