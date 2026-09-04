{.used.}

import chronos, results, testutils/unittests
import libp2p/[switch, peerinfo, crypto/crypto, extended_peer_record, signed_envelope]
import
  logos_delivery/waku/discovery/signed_service_record,
  ../testlib/common,
  ../testlib/wakucore

suite "Signed service record":
  asyncTest "encodes this node's identity, the one service, and verifies":
    let switch = newTestSwitch()
    await switch.start()
    defer:
      await switch.stop()
    let peerInfo = switch.peerInfo

    let bytes = signedServiceRecord(
        peerInfo, peerInfo.privateKey, "/logos/delivery", @[1'u8, 2, 3]
      )
      .expect("signs")

    let decoded = SignedExtendedPeerRecord.decode(bytes).expect("decodes")
    decoded.checkValid().expect("signature matches the record's peer id")
    check:
      decoded.data.peerId == peerInfo.peerId
      decoded.data.addresses.len == peerInfo.addrs.len
      decoded.data.services.len == 1
      decoded.data.services[0].id == "/logos/delivery"
      decoded.data.services[0].data == Opt.some(@[1'u8, 2, 3])
      decoded.data.seqNo > 0

  asyncTest "a record signed with another key does not verify":
    let switch = newTestSwitch()
    await switch.start()
    defer:
      await switch.stop()

    let bytes = signedServiceRecord(
        switch.peerInfo, generateSecp256k1Key(), "/logos/delivery", @[]
      )
      .expect("signs, wrong key")
    ## decode verifies the envelope signature against the embedded key; the
    ## record's peer id then fails to match it
    check SignedExtendedPeerRecord.decode(bytes).isErr() or
      SignedExtendedPeerRecord.decode(bytes).get().checkValid().isErr()

  test "a node without addresses cannot be advertised":
    let key = generateSecp256k1Key()
    let peerInfo = PeerInfo.new(key)
    check signedServiceRecord(peerInfo, key, "/logos/delivery", @[]).isErr()
