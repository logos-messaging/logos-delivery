import std/[net, sequtils, strutils, json], strformat
import chronicles, chronos, stew/byteutils, results, ffi
import
  waku/waku_core/message/message,
  waku/factory/[validator_signed, waku],
  tools/confutils/cli_args,
  waku/waku_core/message,
  waku/waku_core/topics/pubsub_topic,
  waku/waku_core/topics,
  waku/node/kernel_api/relay,
  waku/waku_relay/protocol,
  waku/node/peer_manager,
  library/events/json_message_event,
  library/declare_lib

proc waku_relay_get_peers_in_mesh(
    ctx: ptr FFIContext[Waku],
    callback: FFICallBack,
    userData: pointer,
    pubSubTopic: cstring,
) {.ffi.} =
  let meshPeers = ctx.myLib[].node.wakuRelay.getPeersInMesh($pubsubTopic).valueOr:
    error "LIST_MESH_PEERS failed", error = error
    return err($error)
  ## returns a comma-separated string of peerIDs
  return ok(meshPeers.mapIt($it).join(","))

proc waku_relay_get_num_peers_in_mesh(
    ctx: ptr FFIContext[Waku],
    callback: FFICallBack,
    userData: pointer,
    pubSubTopic: cstring,
) {.ffi.} =
  let numPeersInMesh = ctx.myLib[].node.wakuRelay.getNumPeersInMesh($pubsubTopic).valueOr:
    error "NUM_MESH_PEERS failed", error = error
    return err($error)
  return ok($numPeersInMesh)

proc waku_relay_get_connected_peers(
    ctx: ptr FFIContext[Waku],
    callback: FFICallBack,
    userData: pointer,
    pubSubTopic: cstring,
) {.ffi.} =
  ## Returns the list of all connected peers to an specific pubsub topic
  let connPeers = ctx.myLib[].node.wakuRelay.getConnectedPeers($pubsubTopic).valueOr:
    error "LIST_CONNECTED_PEERS failed", error = error
    return err($error)
  ## returns a comma-separated string of peerIDs
  return ok(connPeers.mapIt($it).join(","))

proc waku_relay_get_num_connected_peers(
    ctx: ptr FFIContext[Waku],
    callback: FFICallBack,
    userData: pointer,
    pubSubTopic: cstring,
) {.ffi.} =
  let numConnPeers = ctx.myLib[].node.wakuRelay.getNumConnectedPeers($pubsubTopic).valueOr:
    error "NUM_CONNECTED_PEERS failed", error = error
    return err($error)
  return ok($numConnPeers)

proc waku_relay_add_protected_shard(
    ctx: ptr FFIContext[Waku],
    callback: FFICallBack,
    userData: pointer,
    clusterId: cint,
    shardId: cint,
    publicKey: cstring,
) {.ffi.} =
  ## Protects a shard with a public key
  try:
    let relayShard = RelayShard(clusterId: uint16(clusterId), shardId: uint16(shardId))
    let protectedShard = ProtectedShard.parseCmdArg($relayShard & ":" & $publicKey)
    ctx.myLib[].node.wakuRelay.addSignedShardsValidator(
      @[protectedShard], uint16(clusterId)
    )
  except ValueError as exc:
    return err("ERROR in waku_relay_add_protected_shard: " & exc.msg)

  return ok("")

proc waku_relay_subscribe(
    ctx: ptr FFIContext[Waku],
    callback: FFICallBack,
    userData: pointer,
    pubSubTopic: cstring,
) {.ffi.} =
  echo "Subscribing to topic: " & $pubSubTopic & " ..."
  proc onReceivedMessage(ctx: ptr FFIContext[Waku]): WakuRelayHandler =
    return proc(pubsubTopic: PubsubTopic, msg: WakuMessage) {.async.} =
      callEventCallback(ctx, "onReceivedMessage"):
        $JsonMessageEvent.new(pubsubTopic, msg)

  var cb = onReceivedMessage(ctx)

  ctx.myLib[].node.subscribe(
    (kind: SubscriptionKind.PubsubSub, topic: $pubsubTopic),
    handler = WakuRelayHandler(cb),
  ).isOkOr:
    error "SUBSCRIBE failed", error = error
    return err($error)
  return ok("")

proc waku_relay_unsubscribe(
    ctx: ptr FFIContext[Waku],
    callback: FFICallBack,
    userData: pointer,
    pubSubTopic: cstring,
) {.ffi.} =
  ctx.myLib[].node.unsubscribe((kind: SubscriptionKind.PubsubSub, topic: $pubsubTopic)).isOkOr:
    error "UNSUBSCRIBE failed", error = error
    return err($error)

  return ok("")

proc waku_relay_publish(
    ctx: ptr FFIContext[Waku],
    callback: FFICallBack,
    userData: pointer,
    pubSubTopic: cstring,
    jsonWakuMessage: cstring,
    timeoutMs: cuint,
) {.ffi.} =
  var
    # https://rfc.vac.dev/spec/36/#extern-char-waku_relay_publishchar-messagejson-char-pubsubtopic-int-timeoutms
    jsonMessage: JsonMessage
  try:
    let jsonContent = parseJson($jsonWakuMessage)
    jsonMessage = JsonMessage.fromJsonNode(jsonContent).valueOr:
      raise newException(JsonParsingError, $error)
  except JsonParsingError as exc:
    return err(fmt"Error parsing json message: {exc.msg}")

  let msg = json_message_event.toWakuMessage(jsonMessage).valueOr:
    return err("Problem building the WakuMessage: " & $error)

  (await ctx.myLib[].node.wakuRelay.publish($pubsubTopic, msg)).isOkOr:
    error "PUBLISH failed", error = error
    return err($error)

  let msgHash = computeMessageHash($pubSubTopic, msg).to0xHex
  return ok(msgHash)

proc waku_default_pubsub_topic(
    ctx: ptr FFIContext[Waku], callback: FFICallBack, userData: pointer
) {.ffi.} =
  # https://rfc.vac.dev/spec/36/#extern-char-waku_default_pubsub_topic
  return ok(DefaultPubsubTopic)

proc waku_content_topic(
    ctx: ptr FFIContext[Waku],
    callback: FFICallBack,
    userData: pointer,
    appName: cstring,
    appVersion: cuint,
    contentTopicName: cstring,
    encoding: cstring,
) {.ffi.} =
  # https://rfc.vac.dev/spec/36/#extern-char-waku_content_topicchar-applicationname-unsigned-int-applicationversion-char-contenttopicname-char-encoding

  return ok(fmt"/{$appName}/{$appVersion}/{$contentTopicName}/{$encoding}")

proc waku_pubsub_topic(
    ctx: ptr FFIContext[Waku],
    callback: FFICallBack,
    userData: pointer,
    topicName: cstring,
) {.ffi.} =
  # https://rfc.vac.dev/spec/36/#extern-char-waku_pubsub_topicchar-name-char-encoding
  return ok(fmt"/waku/2/{$topicName}")
