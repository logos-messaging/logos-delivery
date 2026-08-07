import std/[strutils, json]
import chronicles, chronos, results, ffi
import
  logos_delivery,
  logos_delivery/waku/waku_core/topics/pubsub_topic,
  logos_delivery/waku/waku_core/message,
  logos_delivery/waku/waku_relay/protocol,
  library/events/json_message_event,
  library/declare_lib

proc waku_relay_get_peers_in_mesh(
    self: LogosDelivery, pubSubTopic: string
): Future[Result[string, string]] {.ffi.} =
  ## returns a comma-separated string of peerIDs
  let peers = (await self.waku.relayPeersInMesh(PubsubTopic(pubSubTopic))).valueOr:
    error "LIST_MESH_PEERS failed", error = error
    return err(error)
  return ok(peers.join(","))

proc waku_relay_get_num_peers_in_mesh(
    self: LogosDelivery, pubSubTopic: string
): Future[Result[string, string]] {.ffi.} =
  let n = (await self.waku.relayNumPeersInMesh(PubsubTopic(pubSubTopic))).valueOr:
    error "NUM_MESH_PEERS failed", error = error
    return err(error)
  return ok($n)

proc waku_relay_get_connected_peers(
    self: LogosDelivery, pubSubTopic: string
): Future[Result[string, string]] {.ffi.} =
  ## Returns the list of all connected peers to an specific pubsub topic
  let peers = (await self.waku.relayConnectedPeers(PubsubTopic(pubSubTopic))).valueOr:
    error "LIST_CONNECTED_PEERS failed", error = error
    return err(error)
  return ok(peers.join(","))

proc waku_relay_get_num_connected_peers(
    self: LogosDelivery, pubSubTopic: string
): Future[Result[string, string]] {.ffi.} =
  let n = (await self.waku.relayNumConnectedPeers(PubsubTopic(pubSubTopic))).valueOr:
    error "NUM_CONNECTED_PEERS failed", error = error
    return err(error)
  return ok($n)

proc waku_relay_add_protected_shard(
    self: LogosDelivery, clusterId: uint16, shardId: uint16, publicKey: string
): Future[Result[string, string]] {.ffi.} =
  ## Protects a shard with a public key
  (await self.waku.relayAddProtectedShard(clusterId, shardId, publicKey)).isOkOr:
    return err(error)
  return ok("")

proc waku_relay_subscribe(
    self: LogosDelivery, pubSubTopic: string
): Future[Result[string, string]] {.ffi.} =
  proc onReceivedMessage(): WakuRelayHandler =
    return proc(pubsubTopic: PubsubTopic, msg: WakuMessage) {.async.} =
      emitEvent("onReceivedMessage"):
        $JsonMessageEvent.new(pubsubTopic, msg)

  (
    await self.waku.relaySubscribe(
      PubsubTopic(pubSubTopic), WakuRelayHandler(onReceivedMessage())
    )
  ).isOkOr:
    error "SUBSCRIBE failed", error = error
    return err(error)
  return ok("")

proc waku_relay_unsubscribe(
    self: LogosDelivery, pubSubTopic: string
): Future[Result[string, string]] {.ffi.} =
  (await self.waku.relayUnsubscribe(PubsubTopic(pubSubTopic))).isOkOr:
    error "UNSUBSCRIBE failed", error = error
    return err(error)
  return ok("")

proc waku_relay_publish(
    self: LogosDelivery, pubSubTopic: string, jsonWakuMessage: string, timeoutMs: uint32
): Future[Result[string, string]] {.ffi.} =
  var jsonMessage: JsonMessage
  try:
    let jsonContent = parseJson(jsonWakuMessage)
    jsonMessage = JsonMessage.fromJsonNode(jsonContent).valueOr:
      raise newException(JsonParsingError, $error)
  except JsonParsingError as e:
    return err("Error parsing json message: " & e.msg)

  let msg = json_message_event.toWakuMessage(jsonMessage).valueOr:
    return err("Problem building the WakuMessage: " & $error)

  let msgHash = (await self.waku.relayPublish(PubsubTopic(pubSubTopic), msg, timeoutMs)).valueOr:
    error "PUBLISH failed", error = error
    return err(error)
  return ok(msgHash)

proc waku_default_pubsub_topic(
    self: LogosDelivery
): Future[Result[string, string]] {.ffi.} =
  let topic = (await self.waku.defaultPubsubTopic()).valueOr:
    return err(error)
  return ok(string(topic))

proc waku_content_topic(
    self: LogosDelivery,
    appName: string,
    appVersion: uint32,
    contentTopicName: string,
    encoding: string,
): Future[Result[string, string]] {.ffi.} =
  let topic = (
    await self.waku.buildContentTopic(appName, appVersion, contentTopicName, encoding)
  ).valueOr:
    return err(error)
  return ok(string(topic))

proc waku_pubsub_topic(
    self: LogosDelivery, topicName: string
): Future[Result[string, string]] {.ffi.} =
  let topic = (await self.waku.buildPubsubTopic(topicName)).valueOr:
    return err(error)
  return ok(string(topic))
