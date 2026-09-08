## Per-channel encryption, in pure Nim. Three channels, three schemes:
##
##   #secure -> AES-256-GCM, fresh nonce per message
##   #toy    -> XOR keystream, to show the schemes are independent
##   #plain  -> nothing registered, payloads pass through
##
## Build: make example2   ->   ./build/channel_encryption_example

import std/[sequtils, strutils]
import std/net
import chronos, results, confutils, confutils/defs
import nimcrypto/[bcmode, rijndael, sysrand]
import stew/byteutils

import logos_delivery

type CliArgs = object
  ethRpcEndpoint* {.
    defaultValue: "", desc: "ETH RPC Endpoint, if passed, RLN is enabled"
  .}: string
  ## Off the defaults so the example can run beside another node.
  tcpPort* {.defaultValue: 60010, desc: "libp2p TCP port".}: uint16
  discv5UdpPort* {.defaultValue: 9010, desc: "discv5 UDP port".}: uint16

const
  SecureChannel = ChannelId("#secure")
  ToyChannel = ChannelId("#toy")
  PlainChannel = ChannelId("#plain")

  NonceLen = 12 ## 96-bit, the size GCM is specified around
  TagLen = 16
  KeyLen = 32

## AES-256-GCM. An AEAD rather than a stream cipher on purpose: the
## plaintext is an SDS envelope that goes straight into a protobuf decoder
## on the far side, so it must be tamper-evident, not merely unreadable.

var EmptyAad: array[0, byte]

proc aesGcmSeal(
    key: array[KeyLen, byte], plaintext: seq[byte]
): Result[seq[byte], string] =
  ## Wire layout: nonce || ciphertext || tag.
  var nonce: array[NonceLen, byte]
  if randomBytes(nonce) != NonceLen:
    return err("could not obtain a random nonce")

  try:
    var ctx: GCM[aes256]
    ctx.init(key, nonce, EmptyAad)

    var ciphertext = newSeq[byte](plaintext.len)
    if plaintext.len > 0: # nimcrypto's `encrypt` asserts on empty input
      ctx.encrypt(plaintext, ciphertext)

    var tag: array[TagLen, byte]
    ctx.getTag(tag)
    ctx.clear()

    return ok(@nonce & ciphertext & @tag)
  except CatchableError as e:
    return err("AES-GCM seal failed: " & e.msg)

func constantTimeEq(a, b: openArray[byte]): bool =
  ## Never leak how many leading tag bytes matched.
  if a.len != b.len:
    return false
  var diff: byte = 0
  for i in 0 ..< a.len:
    diff = diff or (a[i] xor b[i])
  return diff == 0

proc aesGcmOpen(key: array[KeyLen, byte], wire: seq[byte]): Result[seq[byte], string] =
  if wire.len < NonceLen + TagLen:
    return err("ciphertext too short to carry a nonce and a tag")

  let ciphertext = wire[NonceLen ..< wire.len - TagLen]

  try:
    var ctx: GCM[aes256]
    ctx.init(key, wire[0 ..< NonceLen], EmptyAad)

    var plaintext = newSeq[byte](ciphertext.len)
    if ciphertext.len > 0:
      ctx.decrypt(ciphertext, plaintext)

    var tag: array[TagLen, byte]
    ctx.getTag(tag)
    ctx.clear()

    # Unauthenticated plaintext is attacker-controlled SDS decoder input.
    if not constantTimeEq(tag, wire[wire.len - TagLen ..< wire.len]):
      return err("authentication tag mismatch")

    return ok(plaintext)
  except CatchableError as e:
    return err("AES-GCM open failed: " & e.msg)

proc aesGcmCrypto(
    key: array[KeyLen, byte]
): tuple[encrypt: ChannelCryptoFn, decrypt: ChannelCryptoFn] =
  let encrypt = proc(
      payload: seq[byte]
  ): Future[Result[seq[byte], string]] {.async: (raises: []).} =
    return aesGcmSeal(key, payload)

  let decrypt = proc(
      payload: seq[byte]
  ): Future[Result[seq[byte], string]] {.async: (raises: []).} =
    return aesGcmOpen(key, payload)

  return (encrypt, decrypt)

## A deliberately trivial second scheme, so the example shows two channels
## that do not understand each other. Not a real cipher.

func xorCrypto(
    key: seq[byte]
): tuple[encrypt: ChannelCryptoFn, decrypt: ChannelCryptoFn] =
  let apply = proc(
      payload: seq[byte]
  ): Future[Result[seq[byte], string]] {.async: (raises: []).} =
    if key.len == 0:
      return err("empty key")
    var output = newSeq[byte](payload.len)
    for i in 0 ..< payload.len:
      output[i] = payload[i] xor key[i mod key.len]
    return ok(output)

  # XOR is its own inverse: same closure both directions.
  return (apply, apply)

## ---------------------------------------------------------------------

proc selfTest(
    name: string, crypto: tuple[encrypt, decrypt: ChannelCryptoFn]
) {.async.} =
  ## Round-trips the pair locally, so running this is meaningful with no
  ## peers around.
  let plaintext = "the quick brown fox".toBytes()

  let sealed = (await crypto.encrypt(plaintext)).valueOr:
    echo "[", name, "] encrypt failed: ", error
    return
  let opened = (await crypto.decrypt(sealed)).valueOr:
    echo "[", name, "] decrypt failed: ", error
    return

  echo "[",
    name,
    "] ",
    plaintext.len,
    "B plaintext -> ",
    sealed.len,
    "B on the wire, round-trip ",
    (if opened == plaintext: "OK" else: "MISMATCH")
  echo "[",
    name, "]   wire: ", byteutils.toHex(sealed[0 ..< min(24, sealed.len)]), "..."

  # Identical ciphertext twice would mean the nonce is being reused.
  let sealedAgain = (await crypto.encrypt(plaintext)).valueOr:
    return
  if sealed == sealedAgain:
    echo "[", name, "]   WARNING: identical ciphertext twice (nonce reuse?)"

proc runChannels(logos: LogosDelivery) {.async.} =
  discard ChannelMessageReceivedEvent.listen(
    proc(evt: ChannelMessageReceivedEvent) {.async: (raises: []).} =
      echo "<- [",
        evt.channelId, "] from ", evt.senderId, ": ", string.fromBytes(evt.payload)
  )

  discard ChannelMessageErrorEvent.listen(
    proc(evt: ChannelMessageErrorEvent) {.async: (raises: []).} =
      echo "!! [", evt.channelId, "] ", evt.error
  )

  # A real application derives these. A hard-coded key is the worst thing
  # anyone could copy out of this file.
  var secureKey: array[KeyLen, byte]
  if randomBytes(secureKey) != KeyLen:
    echo "could not generate a channel key"
    return

  let aes = aesGcmCrypto(secureKey)
  let xorc = xorCrypto("a-toy-key".toBytes())

  echo "--- cipher self-test ---"
  await selfTest("#secure/AES-256-GCM", aes)
  await selfTest("#toy/XOR", xorc)
  echo "------------------------"

  # Registered before the channels exist, so nothing can arrive in the clear.
  logos.reliableChannelManager.setChannelEncryption(
    SecureChannel, aes.encrypt, aes.decrypt
  ).isOkOr:
    echo "failed to register AES on ", SecureChannel, ": ", error
    return

  logos.reliableChannelManager.setChannelEncryption(
    ToyChannel, xorc.encrypt, xorc.decrypt
  ).isOkOr:
    echo "failed to register XOR on ", ToyChannel, ": ", error
    return

  for (channelId, contentTopic) in [
    (SecureChannel, ContentTopic("/example/1/secure/proto")),
    (ToyChannel, ContentTopic("/example/1/toy/proto")),
    (PlainChannel, ContentTopic("/example/1/plain/proto")),
  ]:
    logos.reliableChannelManager.createReliableChannel(
      channelId, contentTopic, SdsParticipantID("channel-encryption-example")
    ).isOkOr:
      echo "failed to create ", channelId, ": ", error
      return
    echo "created ", channelId, " on ", contentTopic

  var counter = 0
  while true:
    for channelId in [SecureChannel, ToyChannel, PlainChannel]:
      let payload = ("hello from " & $channelId & " #" & $counter).toBytes()
      let reqId = (await logos.reliableChannelManager.send(channelId, payload)).valueOr:
        echo "-> [", channelId, "] send failed: ", error
        continue
      echo "-> [", channelId, "] sent, requestId ", reqId
    counter.inc()
    await sleepAsync(15.seconds)

when isMainModule:
  let args = CliArgs.load()

  var conf = defaultWakuNodeConf().valueOr:
    echo "Failed to create default config: ", error
    quit(QuitFailure)

  conf.entryLayer = EntryLayer.channels
  conf.tcpPort = Port(args.tcpPort)
  conf.discv5UdpPort = Port(args.discv5UdpPort)

  if args.ethRpcEndpoint == "":
    conf.preset = "logos.dev"
  else:
    conf.preset = "twn"
    conf.ethClientUrls = @[EthRpcUrl(args.ethRpcEndpoint)]

  let node = (waitFor LogosDelivery.new(conf)).valueOr:
    echo "Failed to create node: ", error
    quit(QuitFailure)

  (waitFor node.start()).isOkOr:
    echo "Failed to start node: ", error
    quit(QuitFailure)

  echo "Node started."

  asyncSpawn runChannels(node)

  runForever()
