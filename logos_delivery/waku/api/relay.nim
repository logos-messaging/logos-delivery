## Waku layer API — relay (gossipsub) operations.
{.push raises: [].}

import std/sequtils
import results, chronos, chronicles, secp256k1, stew/byteutils

import logos_delivery/waku/waku
import
  logos_delivery/waku/[
    waku_core,
    node/waku_node,
    node/waku_node/relay,
    node/subscription_manager,
    waku_relay/protocol,
    factory/waku_conf,
    factory/validator_signed,
  ]

proc relayPublish*(
    self: Waku, pubsubTopic: PubsubTopic, message: WakuMessage, timeoutMs: uint32
): Future[Result[string, string]] {.async.} =
  ## Publishes `message` and returns its message hash (0x-hex).
  try:
    if self.node.wakuRelay.isNil():
      return err("relayPublish: WakuRelay not mounted")

    (await self.node.wakuRelay.publish(pubsubTopic, message)).isOkOr:
      return err($error)

    return ok(computeMessageHash(pubsubTopic, message).to0xHex)
  except CatchableError as e:
    return err(e.msg)

proc relaySubscribe*(
    self: Waku,
    pubsubTopic: PubsubTopic,
    handler: WakuRelayHandler = WakuRelayHandler(nil),
): Future[Result[bool, string]] {.async.} =
  ## Subscribes to `pubsubTopic`. `handler` (optional) is invoked per message;
  ## pass nil to subscribe without a message callback.
  try:
    if self.node.wakuRelay.isNil():
      return err("relaySubscribe: WakuRelay not mounted")

    self.node.subscribe((kind: SubscriptionKind.PubsubSub, topic: pubsubTopic), handler).isOkOr:
      return err($error)

    return ok(true)
  except CatchableError as e:
    return err(e.msg)

proc relayUnsubscribe*(
    self: Waku, pubsubTopic: PubsubTopic
): Future[Result[bool, string]] {.async.} =
  try:
    if self.node.wakuRelay.isNil():
      return err("relayUnsubscribe: WakuRelay not mounted")

    self.node.unsubscribe((kind: SubscriptionKind.PubsubSub, topic: pubsubTopic)).isOkOr:
      return err($error)

    return ok(true)
  except CatchableError as e:
    return err(e.msg)

proc relayAddProtectedShard*(
    self: Waku, clusterId: uint16, shardId: uint16, publicKey: string
): Future[Result[bool, string]] {.async.} =
  try:
    if self.node.wakuRelay.isNil():
      return err("relayAddProtectedShard: WakuRelay not mounted")

    let pubKey = SkPublicKey.fromHex(publicKey).valueOr:
      return err("relayAddProtectedShard: invalid public key: " & $error)

    let protectedShard = ProtectedShard(shard: shardId, key: pubKey)
    self.node.wakuRelay.addSignedShardsValidator(@[protectedShard], clusterId)
    return ok(true)
  except CatchableError as e:
    return err(e.msg)

proc relayConnectedPeers*(
    self: Waku, pubsubTopic: PubsubTopic
): Future[Result[seq[string], string]] {.async.} =
  try:
    if self.node.wakuRelay.isNil():
      return err("relayConnectedPeers: WakuRelay not mounted")

    let connPeers = self.node.wakuRelay.getConnectedPeers(pubsubTopic).valueOr:
      return err($error)

    return ok(connPeers.mapIt($it))
  except CatchableError as e:
    return err(e.msg)

proc relayPeersInMesh*(
    self: Waku, pubsubTopic: PubsubTopic
): Future[Result[seq[string], string]] {.async.} =
  try:
    if self.node.wakuRelay.isNil():
      return err("relayPeersInMesh: WakuRelay not mounted")

    let meshPeers = self.node.wakuRelay.getPeersInMesh(pubsubTopic).valueOr:
      return err($error)

    return ok(meshPeers.mapIt($it))
  except CatchableError as e:
    return err(e.msg)

proc relayNumPeersInMesh*(
    self: Waku, pubsubTopic: PubsubTopic
): Future[Result[int, string]] {.async.} =
  try:
    if self.node.wakuRelay.isNil():
      return err("relayNumPeersInMesh: WakuRelay not mounted")
    let n = self.node.wakuRelay.getNumPeersInMesh(pubsubTopic).valueOr:
      return err($error)
    return ok(n)
  except CatchableError as e:
    return err(e.msg)

proc relayNumConnectedPeers*(
    self: Waku, pubsubTopic: PubsubTopic
): Future[Result[int, string]] {.async.} =
  try:
    if self.node.wakuRelay.isNil():
      return err("relayNumConnectedPeers: WakuRelay not mounted")
    let n = self.node.wakuRelay.getNumConnectedPeers(pubsubTopic).valueOr:
      return err($error)
    return ok(n)
  except CatchableError as e:
    return err(e.msg)
