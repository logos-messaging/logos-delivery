{.push raises: [].}

import
  results,
  waku/[common/logging, waku_node, waku_rln_relay],
  ./erc_5564_interface as StealthCommitmentFFI,
  ./node_spec,
  ./wire_spec

export wire_spec, logging

type StealthCommitmentProtocol* = object
  waku: Waku
  contentTopic: string
  spendingKeyPair: StealthCommitmentFFI.KeyPair
  viewingKeyPair: StealthCommitmentFFI.KeyPair

proc deserialize(
    T: type StealthCommitmentFFI.PublicKey, v: SerializedKey
): Result[T, string] =
  # deserialize seq[byte] into array[32, uint8]
  if v.len != 32:
    return err("invalid key length")
  var buf: array[32, uint8]
  for i in 0 ..< v.len:
    buf[i] = v[i]
  return ok(buf)

proc serialize(
    v: StealthCommitmentFFI.PublicKey | StealthCommitmentFFI.PrivateKey
): SerializedKey =
  # serialize array[32, uint8] into seq[byte]
  var buf = newSeq[byte](v.len)
  for i in 0 ..< v.len:
    buf[i] = v[i]
  return buf

proc sendThruWaku*(
    self: StealthCommitmentProtocol, msg: seq[byte]
): Future[Result[void, string]] {.async.} =
  let time = getTime().toUnix()
  var message = WakuMessage(
    payload: msg,
    contentTopic: self.contentTopic,
    version: 0,
    timestamp: getNanosecondTime(time),
  )

  (self.waku.node.wakuRlnRelay.appendRLNProof(message, float64(time))).isOkOr:
    return err("could not append rate limit proof to the message: " & $error)

  (await self.waku.node.publish(some(DefaultPubsubTopic), message)).isOkOr:
    return err("failed to publish message: " & $error)

  info "rate limit proof is appended to the message"

  return ok()

proc sendRequest*(
    self: StealthCommitmentProtocol
): Future[Result[void, string]] {.async.} =
  let request = constructRequest(
      serialize(self.spendingKeyPair.publicKey),
      serialize(self.viewingKeyPair.publicKey),
    )
    .encode()
  try:
    (await self.sendThruWaku(request.buffer)).isOkOr:
      return err("Could not send stealth commitment payload thru waku: " & $error)
  except CatchableError:
    return err(
      "Could not send stealth commitment payload thru waku: " & getCurrentExceptionMsg()
    )
  return ok()

proc sendResponse*(
    self: StealthCommitmentProtocol,
    stealthCommitment: StealthCommitmentFFI.PublicKey,
    ephemeralPubKey: StealthCommitmentFFI.PublicKey,
    viewTag: uint64,
): Future[Result[void, string]] {.async.} =
  let response = constructResponse(
      serialize(stealthCommitment), serialize(ephemeralPubKey), viewTag
    )
    .encode()
  try:
    (await self.sendThruWaku(response.buffer)).isOkOr:
      return err("Could not send stealth commitment payload thru waku: " & $error)
  except CatchableError:
    return err(
      "Could not send stealth commitment payload thru waku: " & getCurrentExceptionMsg()
    )
  return ok()

type SCPHandler* = proc(msg: WakuMessage): Future[void] {.async.}
proc getSCPHandler(self: StealthCommitmentProtocol): SCPHandler =
  let handler = proc(msg: WakuMessage): Future[void] {.async.} =
    let decoded = WakuStealthCommitmentMsg.decode(msg.payload).valueOr:
      error "could not decode scp message", error = error
      quit(QuitFailure)
    if decoded.request == false:
      # check if the generated stealth commitment belongs to the receiver
      # if not, continue
      let ephemeralPubKey = deserialize(
        StealthCommitmentFFI.PublicKey, decoded.ephemeralPubKey.get()
      ).valueOr:
        error "could not deserialize ephemeral public key: ", error = error
        quit(QuitFailure)
      let stealthCommitmentPrivateKey = StealthCommitmentFFI.generateStealthPrivateKey(
        ephemeralPubKey,
        self.spendingKeyPair.privateKey,
        self.viewingKeyPair.privateKey,
        decoded.viewTag.get(),
      ).valueOr:
        error "received stealth commitment does not belong to the receiver: ",
          error = error
        quit(QuitFailure)
      info "received stealth commitment belongs to the receiver: ",
        stealthCommitmentPrivateKey,
        stealthCommitmentPubKey = decoded.stealthCommitment.get()
      return
    # send response
    # deseralize the keys
    let spendingKey = deserialize(
      StealthCommitmentFFI.PublicKey, decoded.spendingPubKey.get()
    ).valueOr:
      error "could not deserialize spending key: ", error = error
      quit(QuitFailure)
    let viewingKey = (
      deserialize(StealthCommitmentFFI.PublicKey, decoded.viewingPubKey.get())
    ).valueOr:
      error "could not deserialize viewing key: ", error = error
      quit(QuitFailure)

    info "received spending key", spendingKey
    info "received viewing key", viewingKey
    let ephemeralKeyPair = StealthCommitmentFFI.generateKeyPair().valueOr:
      error "could not generate ephemeral key pair: ", error = error
      quit(QuitFailure)

    let stealthCommitment = StealthCommitmentFFI.generateStealthCommitment(
      spendingKey, viewingKey, ephemeralKeyPair.privateKey
    ).valueOr:
      error "could not generate stealth commitment: ", error = error
      quit(QuitFailure)

    (
      await self.sendResponse(
        stealthCommitment.stealthCommitment, ephemeralKeyPair.publicKey,
        stealthCommitment.viewTag,
      )
    ).isOkOr:
      error "could not send response: ", error = $error

  return handler

proc new*(
    waku: Waku, contentTopic = ContentTopic("/wakustealthcommitments/1/app/proto")
): Result[StealthCommitmentProtocol, string] =
  let spendingKeyPair = StealthCommitmentFFI.generateKeyPair().valueOr:
    return err("could not generate spending key pair: " & $error)
  let viewingKeyPair = StealthCommitmentFFI.generateKeyPair().valueOr:
    return err("could not generate viewing key pair: " & $error)

  info "spending public key", publicKey = spendingKeyPair.publicKey
  info "viewing public key", publicKey = viewingKeyPair.publicKey

  let SCP = StealthCommitmentProtocol(
    waku: waku,
    contentTopic: contentTopic,
    spendingKeyPair: spendingKeyPair,
    viewingKeyPair: viewingKeyPair,
  )

  proc handler(topic: PubsubTopic, msg: WakuMessage): Future[void] {.async, gcsafe.} =
    let scpHandler = getSCPHandler(SCP)
    if msg.contentTopic == contentTopic:
      try:
        await scpHandler(msg)
      except CatchableError:
        error "could not handle SCP message: ", err = getCurrentExceptionMsg()

  waku.node.subscribe((kind: PubsubSub, topic: DefaultPubsubTopic), some(handler)).isOkOr:
    error "could not subscribe to pubsub topic: ", err = $error
    return err("could not subscribe to pubsub topic: " & $error)
  return ok(SCP)
