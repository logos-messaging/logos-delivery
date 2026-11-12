{.used.}

import
  results,
  std/strutils,
  chronos,
  chronicles,
  libp2p/switch,
  libp2p/protocols/pubsub/pubsub

import
  logos_delivery/waku/
    [waku_relay, node/waku_node, node/peer_manager, waku_core, waku_node],
  ../waku_store/store_utils,
  ../waku_archive/archive_utils,
  ../testlib/wakucore

proc noopRawHandler*(): WakuRelayHandler =
  var handler: WakuRelayHandler
  handler = proc(topic: PubsubTopic, msg: WakuMessage): Future[void] {.async, gcsafe.} =
    discard
  handler

proc newTestWakuRelay*(
    switch = newTestSwitch(), maxMessageSize = int(DefaultMaxWakuMessageSize)
): Future[WakuRelay] {.async.} =
  let proto = WakuRelay.new(switch, maxMessageSize).tryGet()

  let protocolMatcher = proc(proto: string): bool {.gcsafe.} =
    return proto.startsWith(WakuRelayCodec)

  switch.mount(proto, protocolMatcher)

  return proto

proc subscribeToContentTopicWithHandler*(
    node: WakuNode, contentTopic: string
): Future[bool] =
  var completionFut = newFuture[bool]()
  proc relayHandler(
      topic: PubsubTopic, msg: WakuMessage
  ): Future[void] {.async, gcsafe.} =
    completionFut.complete(true)

  (node.subscribe((kind: ContentSub, topic: contentTopic), relayHandler)).isOkOr:
    raiseAssert "Failed to subscribe to content topic " & contentTopic & ": " & error
  return completionFut

proc subscribeCompletionHandler*(node: WakuNode, pubsubTopic: string): Future[bool] =
  var completionFut = newFuture[bool]()
  proc relayHandler(
      topic: PubsubTopic, msg: WakuMessage
  ): Future[void] {.async, gcsafe.} =
    if topic == pubsubTopic:
      completionFut.complete(true)

  (node.subscribe((kind: PubsubSub, topic: pubsubTopic), relayHandler)).isOkOr:
    error "Failed to subscribe to pubsub topic", error
    completionFut.complete(false)
  return completionFut
