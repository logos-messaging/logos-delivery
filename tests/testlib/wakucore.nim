import
  std/times,
  results,
  stew/byteutils,
  chronos,
  chronicles,
  libp2p/switch,
  libp2p/builders,
  libp2p/crypto/crypto as libp2p_keys,
  eth/common/keys as eth_keys
import logos_delivery/waku/waku_core, ./common

# Logging in a generic library proc (e.g. a `T: type X` constructor) binds
# chronicles where it is instantiated, so tests need it in scope even when they
# never log.
export switch, chronicles

# Time

proc now*(): Timestamp =
  getNanosecondTime(getTime().toUnixFloat())

proc ts*(offset = 0, origin = now()): Timestamp =
  origin + getNanosecondTime(int64(offset))

# Switch

proc generateEcdsaKey*(): libp2p_keys.PrivateKey =
  libp2p_keys.PrivateKey.random(ECDSA, common.rng()).get()

proc generateEcdsaKeyPair*(): libp2p_keys.KeyPair =
  libp2p_keys.KeyPair.random(ECDSA, common.rng()).get()

proc generateSecp256k1Key*(): libp2p_keys.PrivateKey =
  libp2p_keys.PrivateKey.random(Secp256k1, common.rng()).get()

proc ethSecp256k1Key*(hex: string): eth_keys.PrivateKey =
  eth_keys.PrivateKey.fromHex(hex).get()

proc newStandardSwitch*(
    privKey = Opt.none(libp2p_keys.PrivateKey),
    addrs: MultiAddress = MultiAddress.init("/ip4/127.0.0.1/tcp/0").get(),
): Switch =
  ## Bare libp2p switch for tests. Replaces nim-libp2p's `newStandardSwitch`,
  ## removed in 2.0.0. Mirrors the *substrate* of the production switch
  ## (`newWakuSwitch`, waku/node/waku_switch.nim): same transport (TCP only — no
  ## QUIC yet, like prod), security (Noise), and muxers (yamux first so it is the
  ## one negotiated, then mplex). Tests therefore run on the same kernel peers
  ## actually use in prod. NB: the removed libp2p `newStandardSwitch` was
  ## mplex-only; mounting yamux here is intentional (match prod's muxer) — do not
  ## "restore" it to mplex-only. Deliberately omits the prod services (autonat, circuit
  ## relay, name resolver, NAT, signed peer record, connection limits): they add
  ## port grief, network delays, and nondeterminism with no value to unit tests.
  ## For a full-stack node, use newTestWakuNode / newWakuSwitch instead.
  var b = SwitchBuilder
    .new()
    .withRng(common.rng())
    .withAddress(addrs)
    .withTcpTransport()
    .withYamux()
    .withMplex()
    .withNoise()
  if privKey.isSome():
    b = b.withPrivateKey(privKey.get())
  b.build()

proc newTestSwitch*(
    key = Opt.none(libp2p_keys.PrivateKey), address = Opt.none(MultiAddress)
): Switch =
  let peerKey = key.get(generateSecp256k1Key())
  let peerAddr = address.get(MultiAddress.init("/ip4/127.0.0.1/tcp/0").get())
  return newStandardSwitch(privKey = Opt.some(peerKey), addrs = peerAddr)

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

proc fakeWakuMessageEncodedAt*(
    encodedSize: int, contentTopic = DefaultContentTopic, ts = now()
): WakuMessage =
  ## A message whose encoded `WakuMessage` has exactly `encodedSize` bytes.
  let emptyMessage =
    fakeWakuMessage(payload = newSeq[byte](0), contentTopic = contentTopic, ts = ts)
  # The payload field adds a tag and a length prefix of one to three bytes
  var payloadLen = encodedSize - emptyMessage.encode().len - 4
  for _ in 0 .. 2:
    var payload = newSeq[byte](payloadLen)
    for i in 0 ..< payloadLen:
      payload[i] = byte(i mod 256)
    let msg = fakeWakuMessage(payload = payload, contentTopic = contentTopic, ts = ts)
    let diff = encodedSize - msg.encode().len
    if diff == 0:
      return msg
    payloadLen += diff
  doAssert false, "no payload length encodes a message of " & $encodedSize & " bytes"
