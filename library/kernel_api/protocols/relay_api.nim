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
    ctx: ptr FFIContext[LogosDelivery],
    callback: FFICallBack,
    userData: pointer,
    pubSubTopic: cstring,
) {.ffi.} =
  let peers = (await ctx.myLib[].waku.relayPeersInMesh(PubsubTopic($pubSubTopic))).valueOr:
    error "LIST_MESH_PEERS failed", error = error
    return err(error)
  ## returns a comma-separated string of peerIDs
  return ok(peers.join(","))

proc waku_relay_get_num_peers_in_mesh(
    ctx: ptr FFIContext[LogosDelivery],
    callback: FFICallBack,
    userData: pointer,
    pubSubTopic: cstring,
) {.ffi.} =
  let n = (await ctx.myLib[].waku.relayNumPeersInMesh(PubsubTopic($pubSubTopic))).valueOr:
    error "NUM_MESH_PEERS failed", error = error
    return err(error)
  return ok($n)

proc waku_relay_get_connected_peers(
    ctx: ptr FFIContext[LogosDelivery],
    callback: FFICallBack,
    userData: pointer,
    pubSubTopic: cstring,
) {.ffi.} =
  ## Returns the list of all connected peers to an specific pubsub topic
  let peers = (await ctx.myLib[].waku.relayConnectedPeers(PubsubTopic($pubSubTopic))).valueOr:
    error "LIST_CONNECTED_PEERS failed", error = error
    return err(error)
  return ok(peers.join(","))

proc waku_relay_get_num_connected_peers(
    ctx: ptr FFIContext[LogosDelivery],
    callback: FFICallBack,
    userData: pointer,
    pubSubTopic: cstring,
) {.ffi.} =
  let n = (await ctx.myLib[].waku.relayNumConnectedPeers(PubsubTopic($pubSubTopic))).valueOr:
    error "NUM_CONNECTED_PEERS failed", error = error
    return err(error)
  return ok($n)

proc waku_relay_add_protected_shard(
    ctx: ptr FFIContext[LogosDelivery],
    callback: FFICallBack,
    userData: pointer,
    clusterId: cint,
    shardId: cint,
    publicKey: cstring,
) {.ffi.} =
  ## Protects a shard with a public key
  (
    await ctx.myLib[].waku.relayAddProtectedShard(
      uint16(clusterId), uint16(shardId), $publicKey
    )
  ).isOkOr:
    return err(error)
  return ok("")

proc waku_relay_subscribe(
    ctx: ptr FFIContext[LogosDelivery],
    callback: FFICallBack,
    userData: pointer,
    pubSubTopic: cstring,
) {.ffi.} =
  proc onReceivedMessage(ctx: ptr FFIContext[LogosDelivery]): WakuRelayHandler =
    return proc(pubsubTopic: PubsubTopic, msg: WakuMessage) {.async.} =
      callEventCallback(ctx, "onReceivedMessage"):
        $JsonMessageEvent.new(pubsubTopic, msg)

  (
    await ctx.myLib[].waku.relaySubscribe(
      PubsubTopic($pubSubTopic), WakuRelayHandler(onReceivedMessage(ctx))
    )
  ).isOkOr:
    error "SUBSCRIBE failed", error = error
    return err(error)
  return ok("")

proc waku_relay_unsubscribe(
    ctx: ptr FFIContext[LogosDelivery],
    callback: FFICallBack,
    userData: pointer,
    pubSubTopic: cstring,
) {.ffi.} =
  (await ctx.myLib[].waku.relayUnsubscribe(PubsubTopic($pubSubTopic))).isOkOr:
    error "UNSUBSCRIBE failed", error = error
    return err(error)
  return ok("")

proc waku_relay_publish(
    ctx: ptr FFIContext[LogosDelivery],
    callback: FFICallBack,
    userData: pointer,
    pubSubTopic: cstring,
    jsonWakuMessage: cstring,
    timeoutMs: cuint,
) {.ffi.} =
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
    await ctx.myLib[].waku.relayPublish(PubsubTopic($pubSubTopic), msg, uint32(timeoutMs))
  ).valueOr:
    error "PUBLISH failed", error = error
    return err(error)
  return ok(msgHash)

proc waku_default_pubsub_topic(
    ctx: ptr FFIContext[LogosDelivery], callback: FFICallBack, userData: pointer
) {.ffi.} =
  let topic = (await ctx.myLib[].waku.defaultPubsubTopic()).valueOr:
    return err(error)
  return ok(string(topic))

proc waku_content_topic(
    ctx: ptr FFIContext[LogosDelivery],
    callback: FFICallBack,
    userData: pointer,
    appName: cstring,
    appVersion: cuint,
    contentTopicName: cstring,
    encoding: cstring,
) {.ffi.} =
  let topic = (
    await ctx.myLib[].waku.buildContentTopic(
      $appName, uint32(appVersion), $contentTopicName, $encoding
    )
  ).valueOr:
    return err(error)
  return ok(string(topic))

proc waku_pubsub_topic(
    ctx: ptr FFIContext[LogosDelivery],
    callback: FFICallBack,
    userData: pointer,
    topicName: cstring,
) {.ffi.} =
  let topic = (await ctx.myLib[].waku.buildPubsubTopic($topicName)).valueOr:
    return err(error)
  return ok(string(topic))
