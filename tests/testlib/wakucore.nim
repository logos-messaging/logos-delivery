import
  std/[options, times],
  results,
  stew/byteutils,
  chronos,
  libp2p/switch,
  libp2p/builders,
  libp2p/crypto/crypto as libp2p_keys,
  eth/keys as eth_keys
import logos_delivery/waku/waku_core, ./common

export switch

# Time

proc now*(): Timestamp =
  getNanosecondTime(getTime().toUnixFloat())

proc ts*(offset = 0, origin = now()): Timestamp =
  origin + getNanosecondTime(int64(offset))

# Switch

proc generateEcdsaKey*(): libp2p_keys.PrivateKey =
  # libp2p v2.0.0's 3-arg `random(T, scheme, rng)` overload now takes the
  # `Rng` wrapper instead of `var HmacDrbgContext`. Wrap our existing
  # `ref HmacDrbgContext` (from `common.rng`) via `newBearSslRng` to satisfy
  # the new signature without re-seeding a fresh PRNG each call.
  libp2p_keys.PrivateKey.random(ECDSA, newBearSslRng(common.rng())).get()

proc generateEcdsaKeyPair*(): libp2p_keys.KeyPair =
  libp2p_keys.KeyPair.random(ECDSA, newBearSslRng(common.rng())).get()

proc generateSecp256k1Key*(): libp2p_keys.PrivateKey =
  libp2p_keys.PrivateKey.random(Secp256k1, newBearSslRng(common.rng())).get()

proc ethSecp256k1Key*(hex: string): eth_keys.PrivateKey =
  eth_keys.PrivateKey.fromHex(hex).get()

proc newTestSwitch*(
    key = none(libp2p_keys.PrivateKey), address = none(MultiAddress)
): Switch =
  # libp2p v2.0.0 dropped the `newStandardSwitch` convenience constructor;
  # callers now compose a `SwitchBuilder` explicitly with the same transport/
  # muxer/security defaults the v1.x helper used (TCP + Mplex + Noise).
  let peerKey = key.get(generateSecp256k1Key())
  let peerAddr = address.get(MultiAddress.init("/ip4/127.0.0.1/tcp/0").get())
  return SwitchBuilder
    .new()
    .withRng(newBearSslRng(common.rng()))
    .withPrivateKey(peerKey)
    .withAddress(peerAddr)
    .withTcpTransport()
    .withMplex()
    .withNoise()
    .build()

# Waku message

export waku_core.DefaultPubsubTopic, waku_core.DefaultContentTopic

proc fakeWakuMessage*(
    payload: string | seq[byte] = "TEST-PAYLOAD",
    contentTopic = DefaultContentTopic,
    meta: string | seq[byte] = newSeq[byte](),
    ts = now(),
    ephemeral = false,
    proof = newSeq[byte](),
): WakuMessage =
  var payloadBytes: seq[byte]
  var metaBytes: seq[byte]

  when payload is string:
    payloadBytes = toBytes(payload)
  else:
    payloadBytes = payload

  when meta is string:
    metaBytes = toBytes(meta)
  else:
    metaBytes = meta

  WakuMessage(
    payload: payloadBytes,
    contentTopic: contentTopic,
    meta: metaBytes,
    version: 2,
    timestamp: ts,
    ephemeral: ephemeral,
    proof: proof,
  )
