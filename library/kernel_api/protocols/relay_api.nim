import std/[strutils, json]
import chronicles, chronos, results, ffi
import
  logos_delivery,
  logos_delivery/waku/waku_core/topics/pubsub_topic,
  logos_delivery/waku/waku_core/message,
  logos_delivery/waku/waku_relay/protocol,
  library/events/event_bodies,
  library/events/json_message_event,
  library/declare_lib

proc waku_relay_get_peers_in_mesh(
    ld: LogosDelivery, pubSubTopic: cstring
): Future[Result[string, string]] {.ffi.} =
  let peers = (await ld.waku.relayPeersInMesh(PubsubTopic($pubSubTopic))).valueOr:
    error "LIST_MESH_PEERS failed", error = error
    return err(error)
  ## returns a comma-separated string of peerIDs
  return ok(peers.join(","))

proc waku_relay_get_num_peers_in_mesh(
    ld: LogosDelivery, pubSubTopic: cstring
): Future[Result[string, string]] {.ffi.} =
  let n = (await ld.waku.relayNumPeersInMesh(PubsubTopic($pubSubTopic))).valueOr:
    error "NUM_MESH_PEERS failed", error = error
    return err(error)
  return ok($n)

proc waku_relay_get_connected_peers(
    ld: LogosDelivery, pubSubTopic: cstring
): Future[Result[string, string]] {.ffi.} =
  ## Returns the list of all connected peers to an specific pubsub topic
  let peers = (await ld.waku.relayConnectedPeers(PubsubTopic($pubSubTopic))).valueOr:
    error "LIST_CONNECTED_PEERS failed", error = error
    return err(error)
  return ok(peers.join(","))

proc waku_relay_get_num_connected_peers(
    ld: LogosDelivery, pubSubTopic: cstring
): Future[Result[string, string]] {.ffi.} =
  let n = (await ld.waku.relayNumConnectedPeers(PubsubTopic($pubSubTopic))).valueOr:
    error "NUM_CONNECTED_PEERS failed", error = error
    return err(error)
  return ok($n)

proc waku_relay_add_protected_shard(
    ld: LogosDelivery, clusterId: cint, shardId: cint, publicKey: cstring
): Future[Result[string, string]] {.ffi.} =
  ## Protects a shard with a public key
  (await ld.waku.relayAddProtectedShard(uint16(clusterId), uint16(shardId), $publicKey)).isOkOr:
    return err(error)
  return ok("")

proc waku_relay_subscribe(
    ld: LogosDelivery, pubSubTopic: cstring
): Future[Result[string, string]] {.ffi.} =
  proc onReceivedMessage(): WakuRelayHandler =
    return proc(pubsubTopic: PubsubTopic, msg: WakuMessage) {.async.} =
      dispatchFFIEventCbor("message", toRelayMessageBody(pubsubTopic, msg))

  (
    await ld.waku.relaySubscribe(
      PubsubTopic($pubSubTopic), WakuRelayHandler(onReceivedMessage())
    )
  ).isOkOr:
    error "SUBSCRIBE failed", error = error
    return err(error)
  return ok("")

proc waku_relay_unsubscribe(
    ld: LogosDelivery, pubSubTopic: cstring
): Future[Result[string, string]] {.ffi.} =
  (await ld.waku.relayUnsubscribe(PubsubTopic($pubSubTopic))).isOkOr:
    error "UNSUBSCRIBE failed", error = error
    return err(error)
  return ok("")

proc waku_relay_publish(
    ld: LogosDelivery, pubSubTopic: cstring, jsonWakuMessage: cstring, timeoutMs: cuint
): Future[Result[string, string]] {.ffi.} =
  var jsonMessage: JsonMessage
  try:
    let jsonContent = parseJson($jsonWakuMessage)
    jsonMessage = JsonMessage.fromJsonNode(jsonContent).valueOr:
      raise newException(JsonParsingError, $error)
  except JsonParsingError as exc:
    return err("Error parsing json message: " & exc.msg)

  let msg = json_message_event.toWakuMessage(jsonMessage).valueOr:
    return err("Problem building the WakuMessage: " & $error)

  let msgHash = (
    await ld.waku.relayPublish(PubsubTopic($pubSubTopic), msg, uint32(timeoutMs))
  ).valueOr:
    error "PUBLISH failed", error = error
    return err(error)
  return ok(msgHash)

proc waku_default_pubsub_topic(
    ld: LogosDelivery
): Future[Result[string, string]] {.ffi.} =
  let topic = (await ld.waku.defaultPubsubTopic()).valueOr:
    return err(error)
  return ok(string(topic))

proc waku_content_topic(
    ld: LogosDelivery,
    appName: cstring,
    appVersion: cuint,
    contentTopicName: cstring,
    encoding: cstring,
): Future[Result[string, string]] {.ffi.} =
  let topic = (
    await ld.waku.buildContentTopic(
      $appName, uint32(appVersion), $contentTopicName, $encoding
    )
  ).valueOr:
    return err(error)
  return ok(string(topic))

proc waku_pubsub_topic(
    ld: LogosDelivery, topicName: cstring
): Future[Result[string, string]] {.ffi.} =
  let topic = (await ld.waku.buildPubsubTopic($topicName)).valueOr:
    return err(error)
  return ok(string(topic))
