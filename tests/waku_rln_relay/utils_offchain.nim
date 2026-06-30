{.used.}

import
  std/[sequtils, tempfiles, options],
  stew/byteutils,
  chronos,
  chronicles,
  libp2p/switch,
  libp2p/protocols/pubsub/pubsub

from std/times import epochTime

import
  ../../../logos_delivery/waku/
    [node/waku_node, node/peer_manager, waku_core, waku_node, rln],
  ../waku_store/store_utils,
  ../waku_archive/archive_utils,
  ../testlib/[wakucore, futures, assertions]

proc setupStaticRln*(
    node: WakuNode,
    identifier: uint,
    rlnRelayEthContractAddress: Option[string] = none(string),
) {.async.} =
  await node.setRlnValidator(
    WakuRlnConfig(dynamic: false, credIndex: some(identifier), epochSizeSec: 1)
  )

proc setupRelayWithStaticRln*(
    node: WakuNode, identifier: uint, shards: seq[RelayShard]
) {.async.} =
  await node.mountRelay(shards)
  await setupStaticRln(node, identifier)

proc subscribeCompletionHandler*(node: WakuNode, pubsubTopic: string): Future[bool] =
  var completionFut = newFuture[bool]()
  proc relayHandler(
      topic: PubsubTopic, msg: WakuMessage
  ): Future[void] {.async, gcsafe.} =
    if topic == pubsubTopic:
      completionFut.complete(true)

  node.subscribe((kind: PubsubSub, topic: pubsubTopic), some(relayHandler)).isOkOr:
    error "failed to subscribe to relay", topic = pubsubTopic, error = error
    completionFut.complete(false)

  return completionFut

proc sendRlnMessage*(
    client: WakuNode,
    pubsubTopic: string,
    contentTopic: string,
    completionFuture: Future[bool],
    payload: seq[byte] = "Hello".toBytes(),
): Future[bool] {.async.} =
  var message = WakuMessage(payload: payload, contentTopic: contentTopic)
  message.proof = (
    await client.rln.generateRLNProof(message.toRLNSignal(), epochTime())
  ).valueOr:
    raiseAssert "generateRLNProof failed: " & error
  discard await client.publish(some(pubsubTopic), message)
  let isCompleted = await completionFuture.withTimeout(FUTURE_TIMEOUT)
  return isCompleted

proc sendRlnMessageWithInvalidProof*(
    client: WakuNode,
    pubsubTopic: string,
    contentTopic: string,
    completionFuture: Future[bool],
    payload: seq[byte] = "Hello".toBytes(),
): Future[bool] {.async.} =
  let extraBytes: seq[byte] = @[byte(1), 2, 3]
  let rateLimitProofRes = await client.rln.groupManager.generateProof(
    concat(payload, extraBytes),
      # we add extra bytes to invalidate proof verification against original payload
    client.rln.getCurrentEpoch(),
  )
  let
    rateLimitProof = rateLimitProofRes.get().encode().buffer
    message =
      WakuMessage(payload: @payload, contentTopic: contentTopic, proof: rateLimitProof)

  discard await client.publish(some(pubsubTopic), message)
  let isCompleted = await completionFuture.withTimeout(FUTURE_TIMEOUT)
  return isCompleted
