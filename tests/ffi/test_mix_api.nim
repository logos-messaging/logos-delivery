{.used.}

import std/json
import chronos, results, stew/byteutils, testutils/unittests
import libp2p/[crypto/crypto, crypto/secp, multiaddress, peerid, peerstore]
import libp2p_mix/[curve25519, pool], brokers/broker_context
import
  logos_delivery,
  logos_delivery/waku/[node/peer_manager, node/waku_node, waku_core],
  library/kernel_api/protocols/mix_api,
  ../testlib/[wakucore, wakunodeconf, nim_main_stub]

suite "waku_mix_add_peer":
  const
    PublicAddr = "/ip4/8.8.8.8/tcp/60501"
    PrivateAddr = "/ip4/192.168.1.1/tcp/60503"

  proc newDelivery(allowAllAddresses = false): Future[LogosDelivery] {.async.} =
    var conf = defaultTestWakuNodeConf()
    conf.mix = Opt.some(true)
    conf.mixAllowAllAddresses = allowAllAddresses
    var delivery: LogosDelivery
    lockNewGlobalBrokerContext:
      delivery = (await LogosDelivery.new(KernelConf(conf))).expect("LogosDelivery.new")
    return delivery

  proc newMixKey(): FieldElement =
    generateKeyPair().expect("mix key pair").publicKey

  proc mixRecord(
      key: crypto.PrivateKey, mixKey: FieldElement, address: string
  ): string =
    $(
      %*{
        "peerId": $PeerId.init(key).tryGet(),
        "multiaddrs": @[address],
        "mixPubKeyHex": byteutils.toHex(fieldElementToBytes(mixKey)),
        "libp2pPubKeyHex": byteutils.toHex(key.getPublicKey().tryGet().skkey.getBytes()),
      }
    )

  asyncTest "a refused mix peer is not stored":
    let delivery = await newDelivery()
    defer:
      discard await delivery.stop()
    let
      node = delivery.waku.node
      key = generateSecp256k1Key()

    let refused =
      await delivery.waku_mix_add_peer(mixRecord(key, newMixKey(), PrivateAddr))
    check:
      refused.isErr()
      not node.switch.peerStore.peerExists(PeerId.init(key).tryGet())
      node.wakuMix.nodePool.len == 0

    let accepted =
      await delivery.waku_mix_add_peer(mixRecord(key, newMixKey(), PublicAddr))
    check:
      accepted.isOk()
      node.getMixNodePoolSize() == 1

  asyncTest "a private address updates the key of a mix peer with a public address":
    ## A path can still use the public address that the peer store has.
    let delivery = await newDelivery()
    defer:
      discard await delivery.stop()
    let
      node = delivery.waku.node
      publicAddr = MultiAddress.init(PublicAddr).tryGet()
      privateAddr = MultiAddress.init(PrivateAddr).tryGet()
      otherAddr = MultiAddress.init("/ip4/192.168.1.2/tcp/60503").tryGet()
      discovered = generateSecp256k1Key()
      dialed = generateSecp256k1Key()

    proc discover(key: crypto.PrivateKey, addrs: seq[MultiAddress]) =
      node.peerManager.addPeer(
        RemotePeerInfo.init(
          PeerId.init(key).tryGet(), addrs, mixPubKey = Opt.some(newMixKey())
        )
      )

    discover(discovered, @[publicAddr, privateAddr, otherAddr])
    discover(dialed, @[privateAddr])
    node.switch.peerStore[LastSeenOutboundBook][PeerId.init(dialed).tryGet()] =
      Opt.some(publicAddr)

    for key in [discovered, dialed]:
      let mixKey = newMixKey()
      let updated =
        await delivery.waku_mix_add_peer(mixRecord(key, mixKey, PrivateAddr))
      check:
        updated.isOk()
        node.switch.peerStore[MixPubKeyBook][PeerId.init(key).tryGet()] == mixKey
    check:
      node.getMixNodePoolSize() == 2
      node.switch.peerStore[AddressBook][PeerId.init(discovered).tryGet()] ==
        @[privateAddr, publicAddr]

  asyncTest "a public address replaces the stored addresses of a mix peer":
    let delivery = await newDelivery()
    defer:
      discard await delivery.stop()
    let
      node = delivery.waku.node
      key = generateSecp256k1Key()
      peerId = PeerId.init(key).tryGet()
      publicAddr = MultiAddress.init(PublicAddr).tryGet()
      privateAddr = MultiAddress.init(PrivateAddr).tryGet()
    node.peerManager.addPeer(RemotePeerInfo.init(peerId, @[privateAddr, publicAddr]))

    let updated =
      await delivery.waku_mix_add_peer(mixRecord(key, newMixKey(), PublicAddr))
    check:
      updated.isOk()
      node.switch.peerStore[AddressBook][peerId] == @[publicAddr]

  asyncTest "a private address is accepted with all addresses allowed":
    let delivery = await newDelivery(allowAllAddresses = true)
    defer:
      discard await delivery.stop()
    let accepted = await delivery.waku_mix_add_peer(
      mixRecord(generateSecp256k1Key(), newMixKey(), PrivateAddr)
    )
    check:
      accepted.isOk()
      delivery.waku.node.getMixNodePoolSize() == 1
