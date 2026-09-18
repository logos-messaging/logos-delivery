import std/json
import chronos, results, ffi, stew/byteutils
import libp2p/[peerid, multiaddress]
import libp2p/crypto/[crypto, secp]
import libp2p_mix/[mix_protocol, mix_node, curve25519, pool]
import logos_delivery, logos_delivery/waku/node/peer_manager
import library/declare_lib

proc waku_mix_get_peer_record(
    self: LogosDelivery
): Future[Result[string, string]] {.ffi.} =
  let mix = self.waku.node.wakuMix
  if mix.isNil():
    return err("Mix is not enabled")
  let info = mix.localMixPubInfo()
  return ok(
    $(
      %*{
        "peerId": $info.peerId,
        "multiaddrs": @[$info.multiAddr],
        "mixPubKeyHex": byteutils.toHex(fieldElementToBytes(info.mixPubKey)),
        "libp2pPubKeyHex":
          byteutils.toHex(self.waku.node.switch.peerInfo.publicKey.skkey.getBytes()),
        "exitEnabled": info.exitEnabled,
      }
    )
  )

proc waku_mix_add_peer(
    self: LogosDelivery, recordJson: string
): Future[Result[string, string]] {.ffi.} =
  let mix = self.waku.node.wakuMix
  if mix.isNil():
    return err("Mix is not enabled")
  try:
    let record = parseJson(recordJson)
    if record.kind != JObject or not record.hasKey("multiaddrs") or
        record["multiaddrs"].kind != JArray or not record.hasKey("exitEnabled") or
        record["multiaddrs"].len == 0 or record.getOrDefault("exitEnabled").kind != JBool:
      return err("Invalid Mix peer record")
    let peerId = PeerId.init(record.getOrDefault("peerId").getStr()).valueOr:
      return err("Invalid Mix peer id")
    let address = MultiAddress.init(record["multiaddrs"][0].getStr()).valueOr:
      return err("Invalid Mix peer address")
    let key = bytesToFieldElement(
      hexToSeqByte(record.getOrDefault("mixPubKeyHex").getStr())
    ).valueOr:
      return err(error)
    let pubkey = SkPublicKey.init(
      hexToSeqByte(record.getOrDefault("libp2pPubKeyHex").getStr())
    ).valueOr:
      return err("Invalid libp2p public key")
    let publicKey = PublicKey(scheme: Secp256k1, skkey: pubkey)
    if PeerId.init(publicKey).valueOr(default(PeerId)) != peerId:
      return err("Mix peer id does not match public key")
    mix.nodePool.add(
      MixPubInfo.init(peerId, address, key, pubkey, record["exitEnabled"].getBool())
    )
    self.waku.node.peerManager.addPeer(
      RemotePeerInfo.init(
        peerId, @[address], publicKey = publicKey, mixPubKey = Opt.some(key)
      )
    )
    return ok("{}")
  except CatchableError as exc:
    return err("Invalid Mix peer record: " & exc.msg)
