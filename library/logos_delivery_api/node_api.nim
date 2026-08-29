import std/json
import chronos, chronicles, results, ffi
import brokers/broker_context
import libp2p/peerid # pull PeerId pretty string formatting
import logos_delivery/waku/common/base64
import
  logos_delivery,
  logos_delivery/waku/node/waku_node,
  logos_delivery/api/types,
  logos_delivery/waku/api/events/health_events,
  logos_delivery/waku/api/events/peer_events,
  logos_delivery/api/conf/logos_delivery_conf_json,
  ../declare_lib,
  ../json_event

# Add JSON serialization for RequestId
proc `%`*(id: RequestId): JsonNode =
  %($id)

proc registerFFIEventListeners(self: LogosDelivery): Result[void, string] =
  ## Bridges every broker event the library re-publishes onto the FFI event
  ## registry. Registered once per node, at creation: the forwarders feed
  ## the context-scoped C listener registry, so they share its create-to-
  ## destroy lifetime. `teardownFFIEventScope` is the other end.
  MessageSentEvent.listen(
    self.waku.brokerCtx,
    proc(event: MessageSentEvent) {.async: (raises: []).} =
      emitEvent("onMessageSent"):
        $newJsonEvent("message_sent", event),
  ).isOkOr:
    chronicles.error "MessageSentEvent.listen failed", err = $error
    return err("MessageSentEvent.listen failed: " & $error)

  MessageErrorEvent.listen(
    self.waku.brokerCtx,
    proc(event: MessageErrorEvent) {.async: (raises: []).} =
      emitEvent("onMessageError"):
        $newJsonEvent("message_error", event),
  ).isOkOr:
    chronicles.error "MessageErrorEvent.listen failed", err = $error
    return err("MessageErrorEvent.listen failed: " & $error)

  MessagePropagatedEvent.listen(
    self.waku.brokerCtx,
    proc(event: MessagePropagatedEvent) {.async: (raises: []).} =
      emitEvent("onMessagePropagated"):
        $newJsonEvent("message_propagated", event),
  ).isOkOr:
    chronicles.error "MessagePropagatedEvent.listen failed", err = $error
    return err("MessagePropagatedEvent.listen failed: " & $error)

  MessageReceivedEvent.listen(
    self.waku.brokerCtx,
    proc(event: MessageReceivedEvent) {.async: (raises: []).} =
      emitEvent("onMessageReceived"):
        $newJsonEvent("message_received", event),
  ).isOkOr:
    chronicles.error "MessageReceivedEvent.listen failed", err = $error
    return err("MessageReceivedEvent.listen failed: " & $error)

  EventConnectionStatusChange.listen(
    self.waku.brokerCtx,
    proc(event: EventConnectionStatusChange) {.async: (raises: []).} =
      emitEvent("onConnectionStatusChange"):
        $newJsonEvent("connection_status_change", event),
  ).isOkOr:
    chronicles.error "ConnectionStatusChange.listen failed", err = $error
    return err("ConnectionStatusChange.listen failed: " & $error)

  EventShardTopicHealthChange.listen(
    self.waku.brokerCtx,
    proc(event: EventShardTopicHealthChange) {.async: (raises: []).} =
      emitEvent("onTopicHealthChange"):
        $(
          %*{
            "eventType": "relay_topic_health_change",
            "pubsubTopic": $event.topic,
            "topicHealth": $event.health,
          }
        ),
  ).isOkOr:
    chronicles.error "EventShardTopicHealthChange.listen failed", err = $error
    return err("EventShardTopicHealthChange.listen failed: " & $error)

  WakuPeerEvent.listen(
    self.waku.brokerCtx,
    proc(event: WakuPeerEvent) {.async: (raises: []).} =
      emitEvent("onConnectionChange"):
        $(
          %*{
            "eventType": "connection_change",
            "peerId": $event.peerId,
            "peerEvent": $event.kind,
          }
        ),
  ).isOkOr:
    chronicles.error "WakuPeerEvent.listen failed", err = $error
    return err("WakuPeerEvent.listen failed: " & $error)

  ChannelMessageReceivedEvent.listen(
    self.waku.brokerCtx,
    proc(event: ChannelMessageReceivedEvent) {.async: (raises: []).} =
      emitEvent("onChannelMessageReceived"):
        $(
          %*{
            "eventType": "channel_message_received",
            "channelId": string(event.channelId),
            "senderId": $event.senderId,
            "payload": string(base64.encode(event.payload)),
          }
        ),
  ).isOkOr:
    chronicles.error "ChannelMessageReceivedEvent.listen failed", err = $error
    return err("ChannelMessageReceivedEvent.listen failed: " & $error)

  ChannelMessageSentEvent.listen(
    self.waku.brokerCtx,
    proc(event: ChannelMessageSentEvent) {.async: (raises: []).} =
      emitEvent("onChannelMessageSent"):
        $newJsonEvent("channel_message_sent", event),
  ).isOkOr:
    chronicles.error "ChannelMessageSentEvent.listen failed", err = $error
    return err("ChannelMessageSentEvent.listen failed: " & $error)

  ChannelMessageErrorEvent.listen(
    self.waku.brokerCtx,
    proc(event: ChannelMessageErrorEvent) {.async: (raises: []).} =
      emitEvent("onChannelMessageError"):
        $newJsonEvent("channel_message_error", event),
  ).isOkOr:
    chronicles.error "ChannelMessageErrorEvent.listen failed", err = $error
    return err("ChannelMessageErrorEvent.listen failed: " & $error)

  return ok()

proc teardownFFIEventScope(self: LogosDelivery) {.async.} =
  ## The node's broker scope dies with the node. Dropping all listeners of
  ## an instance context also deletes its per-event buckets, so an FFI
  ## thread reused for a later node starts with clean broker state.
  await MessageSentEvent.dropAllListeners(self.waku.brokerCtx)
  await MessageErrorEvent.dropAllListeners(self.waku.brokerCtx)
  await MessagePropagatedEvent.dropAllListeners(self.waku.brokerCtx)
  await MessageReceivedEvent.dropAllListeners(self.waku.brokerCtx)
  await EventConnectionStatusChange.dropAllListeners(self.waku.brokerCtx)
  await EventShardTopicHealthChange.dropAllListeners(self.waku.brokerCtx)
  await WakuPeerEvent.dropAllListeners(self.waku.brokerCtx)
  await ChannelMessageReceivedEvent.dropAllListeners(self.waku.brokerCtx)
  await ChannelMessageSentEvent.dropAllListeners(self.waku.brokerCtx)
  await ChannelMessageErrorEvent.dropAllListeners(self.waku.brokerCtx)

proc logosdelivery_create_node(
    configJson: string
): Future[Result[LogosDelivery, string]] {.ffiCtor.} =
  let conf = parseLogosDeliveryConf(configJson).valueOr:
    error "Failed to parse Logos Delivery configuration JSON",
      error = error, configJson = configJson
    return err("failed parseLogosDeliveryConf " & error)

  ## Give each node its own broker scope. This runs on the FFI thread the
  ## node will live on: the first node built on that thread mints the
  ## thread's class context, and every node gets a fresh instance context
  ## under it. The layers read the thread's context as they are built, so
  ## all of the node's listeners land under its scope. nim-ffi reuses FFI
  ## threads across create/destroy cycles; a destroyed node's listeners
  ## exist only under its scope, so a later node on the same thread cannot
  ## reach them, and `teardownFFIEventScope` deletes exactly this node's.
  if threadGlobalBrokerContext() == DefaultBrokerContext:
    discard initThreadBrokerContext()
  setThreadBrokerContext(newInstanceCtx(threadGlobalBrokerContext()))

  let lib = (await LogosDelivery.new(conf)).valueOr:
    let errMsg = $error
    chronicles.error "CreateNodeRequest failed", err = errMsg
    return err(errMsg)

  lib.registerFFIEventListeners().isOkOr:
    await lib.teardownFFIEventScope()
    return err(error)

  return ok(lib)

proc logosdelivery_start_node(
    self: LogosDelivery
): Future[Result[string, string]] {.ffi.} =
  (await self.start()).isOkOr:
    let errMsg = $error
    chronicles.error "START_NODE failed", err = errMsg
    return err("failed to start: " & errMsg)
  return ok("")

proc stopNode(self: LogosDelivery): Future[Result[void, string]] {.async.} =
  if not self.isRunning():
    return ok()

  await self.stop()

proc logosdelivery_stop_node(
    self: LogosDelivery
): Future[Result[string, string]] {.ffi.} =
  (await self.stopNode()).isOkOr:
    let errMsg = $error
    chronicles.error "STOP_NODE failed", err = errMsg
    return err("failed to stop: " & errMsg)
  return ok("")

proc logosdelivery_destroy(self: LogosDelivery) {.ffiDtor.} =
  ## Safety net for a host that skips `stop_node` (#4108): nim-ffi recycles the
  ## worker rather than joining it, so an unstopped node keeps running.
  ## The forwarders registered at create live until here, with the node's
  ## broker scope; `teardownFFIEventScope` is the other end of create.
  (await self.stopNode()).isOkOr:
    chronicles.error "DESTROY failed", err = error
  await self.teardownFFIEventScope()
