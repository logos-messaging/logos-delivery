import
  std/[options, sequtils, strutils],
  results,
  chronos,
  chronicles,
  testutils/unittests,
  libp2p/crypto/crypto as libp2p_keys,
  libp2p/crypto/curve25519,
  libp2p/[peerid, multiaddress, switch, extended_peer_record],
  libp2p/extended_peer_record,
  libp2p/protocols/service_discovery/types as sd_types,
  libp2p_mix/mix_protocol

import
  logos_delivery/waku/discovery/waku_kademlia,
  logos_delivery/waku/waku_core/peers,
  logos_delivery/waku/node/peer_manager/waku_peer_store
import ../testlib/[wakucore, testasync, assertions, futures, testutils]
import ./utils as kad_utils

suite "Waku Kademlia service discovery":
  asyncTest "seed node starts with no bootstrap nodes":
    let
      switch = newTestSwitch()
      wk = kad_utils.newTestKademlia(
        switch, servicesToAdvertise = @[ServiceInfo(id: "/seed/svc/1.0.0", data: @[])]
      )
    await switch.start()
    await wk.start()

    await sleepAsync(FUTURE_TIMEOUT)

    check:
      not wk.protocol.isNil()

    await wk.stop()
    await switch.stop()

  suite "extractMixPubKey":
    proc validKeyBytes(): seq[byte] =
      var b = newSeq[byte](Curve25519KeySize)
      for i in 0 ..< Curve25519KeySize:
        b[i] = byte(i)
      b

    test "non-mix service returns none":
      let svc = ServiceInfo(id: "/foo/1.0.0", data: validKeyBytes())
      check:
        extractMixPubKey(svc).isNone()

    test "mix service with wrong data length returns none":
      let svc = ServiceInfo(id: MixProtocolID, data: @[0u8, 1u8, 2u8])
      check:
        extractMixPubKey(svc).isNone()

    test "mix service with correct length returns some":
      let bytes = validKeyBytes()
      let svc = ServiceInfo(id: MixProtocolID, data: bytes)
      let res = extractMixPubKey(svc)
      require:
        res.isSome()
      let key = res.get()
      check:
        key.getBytes() == bytes

    test "round-trip matches intoCurve25519Key on raw bytes":
      let bytes = validKeyBytes()
      let svc = ServiceInfo(id: MixProtocolID, data: bytes)
      let extracted = extractMixPubKey(svc).get()
      let direct = intoCurve25519Key(bytes)
      check:
        extracted.getBytes() == direct.getBytes()

  suite "remotePeerInfoFrom":
    proc randomPeerId(): PeerId =
      PeerId.init(generateSecp256k1Key()).tryGet()

    proc testAddr(port: uint16): MultiAddress =
      MultiAddress.init("/ip4/127.0.0.1/tcp/" & $port).tryGet()

    proc mixService(data: seq[byte]): ServiceInfo =
      ServiceInfo(id: MixProtocolID, data: data)

    proc validMixService(): ServiceInfo =
      var b = newSeq[byte](Curve25519KeySize)
      for i in 0 ..< Curve25519KeySize:
        b[i] = byte(i)
      mixService(b)

    test "empty addresses returns none":
      let record = buildExtendedPeerRecord(randomPeerId(), @[])
      check:
        remotePeerInfoFrom(record).isNone()

    test "origin set to PeerOrigin.Kademlia":
      let
        pid = randomPeerId()
        record = buildExtendedPeerRecord(pid, @[testAddr(61600)])
        res = remotePeerInfoFrom(record)
      require:
        res.isSome()
      let peerInfo = res.get()
      check:
        peerInfo.origin == PeerOrigin.Kademlia
        peerInfo.peerId == pid

    test "mixPubKey extracted from first mix service":
      let
        pid = randomPeerId()
        svc = validMixService()
        record = buildExtendedPeerRecord(pid, @[testAddr(61600)], @[svc])
        res = remotePeerInfoFrom(record)
      require:
        res.isSome()
      let peerInfo = res.get()
      check:
        peerInfo.mixPubKey.isSome()
        peerInfo.mixPubKey.get().getBytes() == svc.data

    test "mixPubKey stays none when no mix service present":
      let
        pid = randomPeerId()
        svc = ServiceInfo(id: "/other/1.0.0", data: @[1u8])
        record = buildExtendedPeerRecord(pid, @[testAddr(61600)], @[svc])
        res = remotePeerInfoFrom(record)
      require:
        res.isSome()
      check:
        res.get().mixPubKey.isNone()

    test "addresses mapped correctly":
      let
        pid = randomPeerId()
        addrs = @[testAddr(61600), testAddr(61601), testAddr(61602)]
        record = buildExtendedPeerRecord(pid, addrs)
        res = remotePeerInfoFrom(record)
      require:
        res.isSome()
      let peerInfo = res.get()
      check:
        peerInfo.addrs.len == 3
        peerInfo.addrs == addrs

    test "multiple mix services, first one wins":
      let
        pid = randomPeerId()
        firstBytes = block:
          var b = newSeq[byte](Curve25519KeySize)
          for i in 0 ..< Curve25519KeySize:
            b[i] = byte(i)
          b
        secondBytes = block:
          var b = newSeq[byte](Curve25519KeySize)
          for i in 0 ..< Curve25519KeySize:
            b[i] = byte(i + 100)
          b
        record = buildExtendedPeerRecord(
          pid, @[testAddr(61600)], @[mixService(firstBytes), mixService(secondBytes)]
        )
        res = remotePeerInfoFrom(record)
      require:
        res.isSome()
      check:
        res.get().mixPubKey.get().getBytes() == firstBytes

    test "mix service with bad key length is skipped silently":
      let
        pid = randomPeerId()
        badSvc = mixService(@[0u8, 1u8, 2u8])
        record = buildExtendedPeerRecord(pid, @[testAddr(61600)], @[badSvc])
        res = remotePeerInfoFrom(record)
      require:
        res.isSome()
      let peerInfo = res.get()
      check:
        peerInfo.peerId == pid
        peerInfo.mixPubKey.isNone()

  suite "lookupServicePeers":
    asyncTest "returns err when protocol is nil":
      let
        switch = newTestSwitch()
        wk = kad_utils.newTestKademlia(switch)
      wk.protocol = nil
      let res = await wk.lookupServicePeers("/some/service/1.0.0")
      check:
        res.isErr()
        res.error.contains("service discovery not mounted")

    asyncTest "returns ok with empty seq when no advertisements":
      let
        switch = newTestSwitch()
        wk = kad_utils.newTestKademlia(switch)
      await switch.start()
      await wk.start()

      let res = await wk.lookupServicePeers("/nonexistent/service/1.0.0")
      check:
        res.isOk()
        res.value.len == 0

      await wk.stop()
      await switch.stop()
