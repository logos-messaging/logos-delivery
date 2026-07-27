import chronos, chronicles, results, ffi
import
  logos_delivery,
  logos_delivery/waku/node/waku_node,
  logos_delivery/waku/api/events/health_events,
  logos_delivery/waku/api/events/peer_events,
  logos_delivery/api/conf/logos_delivery_conf_json,
  ../declare_lib,
  ../events/event_bodies

proc logosdelivery_create_node(
    configJson: cstring
): Future[Result[LogosDelivery, string]] {.ffiCtor.} =
  let conf = parseLogosDeliveryConf($configJson).valueOr:
    error "Failed to parse Logos Delivery configuration JSON",
      error = error, configJson = $configJson
    return err("failed parseLogosDeliveryConf " & error)

  let node = (await LogosDelivery.new(conf)).valueOr:
    let errMsg = $error
    chronicles.error "create_node failed", err = errMsg
    return err(errMsg)

  return ok(node)

proc logosdelivery_destroy(ld: LogosDelivery) {.ffiDtor.} =
  ## Releases the FFI context. Runs on the caller thread, so the node is
  ## expected to have been stopped with logosdelivery_stop_node beforehand.
  discard

proc logosdelivery_start_node(
    ld: LogosDelivery
): Future[Result[string, string]] {.ffi.} =
  requireInitializedNode(ld, "START_NODE"):
    return err(errMsg)

  # setting up outgoing event listeners
  let sentListener = MessageSentEvent.listen(
    ld.waku.brokerCtx,
    proc(event: MessageSentEvent) {.async: (raises: []).} =
      dispatchFFIEventCbor("message_sent", toFfi(event)),
  ).valueOr:
    chronicles.error "MessageSentEvent.listen failed", err = $error
    return err("MessageSentEvent.listen failed: " & $error)

  let errorListener = MessageErrorEvent.listen(
    ld.waku.brokerCtx,
    proc(event: MessageErrorEvent) {.async: (raises: []).} =
      dispatchFFIEventCbor("message_error", toFfi(event)),
  ).valueOr:
    chronicles.error "MessageErrorEvent.listen failed", err = $error
    return err("MessageErrorEvent.listen failed: " & $error)

  let propagatedListener = MessagePropagatedEvent.listen(
    ld.waku.brokerCtx,
    proc(event: MessagePropagatedEvent) {.async: (raises: []).} =
      dispatchFFIEventCbor("message_propagated", toFfi(event)),
  ).valueOr:
    chronicles.error "MessagePropagatedEvent.listen failed", err = $error
    return err("MessagePropagatedEvent.listen failed: " & $error)

  let receivedListener = MessageReceivedEvent.listen(
    ld.waku.brokerCtx,
    proc(event: MessageReceivedEvent) {.async: (raises: []).} =
      dispatchFFIEventCbor("message_received", toFfi(event)),
  ).valueOr:
    chronicles.error "MessageReceivedEvent.listen failed", err = $error
    return err("MessageReceivedEvent.listen failed: " & $error)

  let ConnectionStatusChangeListener = EventConnectionStatusChange.listen(
    ld.waku.brokerCtx,
    proc(event: EventConnectionStatusChange) {.async: (raises: []).} =
      dispatchFFIEventCbor("connection_status_change", toFfi(event)),
  ).valueOr:
    chronicles.error "ConnectionStatusChange.listen failed", err = $error
    return err("ConnectionStatusChange.listen failed: " & $error)

  let shardTopicHealthListener = EventShardTopicHealthChange.listen(
    ld.waku.brokerCtx,
    proc(event: EventShardTopicHealthChange) {.async: (raises: []).} =
      dispatchFFIEventCbor("relay_topic_health_change", toFfi(event)),
  ).valueOr:
    chronicles.error "EventShardTopicHealthChange.listen failed", err = $error
    return err("EventShardTopicHealthChange.listen failed: " & $error)

  let peerEventListener = WakuPeerEvent.listen(
    ld.waku.brokerCtx,
    proc(event: WakuPeerEvent) {.async: (raises: []).} =
      dispatchFFIEventCbor("connection_change", toFfi(event)),
  ).valueOr:
    chronicles.error "WakuPeerEvent.listen failed", err = $error
    return err("WakuPeerEvent.listen failed: " & $error)

  let channelReceivedListener = ChannelMessageReceivedEvent.listen(
    ld.waku.brokerCtx,
    proc(event: ChannelMessageReceivedEvent) {.async: (raises: []).} =
      dispatchFFIEventCbor("channel_message_received", toFfi(event)),
  ).valueOr:
    chronicles.error "ChannelMessageReceivedEvent.listen failed", err = $error
    return err("ChannelMessageReceivedEvent.listen failed: " & $error)

  let channelSentListener = ChannelMessageSentEvent.listen(
    ld.waku.brokerCtx,
    proc(event: ChannelMessageSentEvent) {.async: (raises: []).} =
      dispatchFFIEventCbor("channel_message_sent", toFfi(event)),
  ).valueOr:
    chronicles.error "ChannelMessageSentEvent.listen failed", err = $error
    return err("ChannelMessageSentEvent.listen failed: " & $error)

  let channelErrorListener = ChannelMessageErrorEvent.listen(
    ld.waku.brokerCtx,
    proc(event: ChannelMessageErrorEvent) {.async: (raises: []).} =
      dispatchFFIEventCbor("channel_message_error", toFfi(event)),
  ).valueOr:
    chronicles.error "ChannelMessageErrorEvent.listen failed", err = $error
    return err("ChannelMessageErrorEvent.listen failed: " & $error)

  (await ld.start()).isOkOr:
    let errMsg = $error
    chronicles.error "START_NODE failed", err = errMsg
    return err("failed to start: " & errMsg)
  return ok("")

proc logosdelivery_stop_node(
    ld: LogosDelivery
): Future[Result[string, string]] {.ffi.} =
  requireInitializedNode(ld, "STOP_NODE"):
    return err(errMsg)

  await MessageErrorEvent.dropAllListeners(ld.waku.brokerCtx)
  await MessageSentEvent.dropAllListeners(ld.waku.brokerCtx)
  await MessagePropagatedEvent.dropAllListeners(ld.waku.brokerCtx)
  await MessageReceivedEvent.dropAllListeners(ld.waku.brokerCtx)
  await EventConnectionStatusChange.dropAllListeners(ld.waku.brokerCtx)
  await EventShardTopicHealthChange.dropAllListeners(ld.waku.brokerCtx)
  await WakuPeerEvent.dropAllListeners(ld.waku.brokerCtx)
  await ChannelMessageReceivedEvent.dropAllListeners(ld.waku.brokerCtx)
  await ChannelMessageSentEvent.dropAllListeners(ld.waku.brokerCtx)
  await ChannelMessageErrorEvent.dropAllListeners(ld.waku.brokerCtx)

  (await ld.stop()).isOkOr:
    let errMsg = $error
    chronicles.error "STOP_NODE failed", err = errMsg
    return err("failed to stop: " & errMsg)
  return ok("")
