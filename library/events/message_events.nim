## Message events: send lifecycle (sent/error/propagated/received) plus raw
## inbound network messages. Each FFI event is fed by an internal broker event.

proc onMessageSent*(
  requestId: string, messageHash: string
) {.ffiEvent: "on_message_sent".}

proc onMessageError*(
  requestId: string, messageHash: string, error: string
) {.ffiEvent: "on_message_error".}

proc onMessagePropagated*(
  requestId: string, messageHash: string
) {.ffiEvent: "on_message_propagated".}

proc onMessageReceived*(messageHash: string) {.ffiEvent: "on_message_received".}

proc onNetworkMessage*(
  pubsubTopic: string, message: WakuMessage
) {.ffiEvent: "on_network_message".}

proc listenMessageEvents(self: LogosDelivery) =
  let brokerCtx = self.waku.brokerCtx

  discard MessageSentEvent.listen(
    brokerCtx,
    proc(e: MessageSentEvent) {.async: (raises: []).} =
      onMessageSent($e.requestId, e.messageHash),
  )
  discard MessageErrorEvent.listen(
    brokerCtx,
    proc(e: MessageErrorEvent) {.async: (raises: []).} =
      onMessageError($e.requestId, e.messageHash, e.error),
  )
  discard MessagePropagatedEvent.listen(
    brokerCtx,
    proc(e: MessagePropagatedEvent) {.async: (raises: []).} =
      onMessagePropagated($e.requestId, e.messageHash),
  )
  discard MessageReceivedEvent.listen(
    brokerCtx,
    proc(e: MessageReceivedEvent) {.async: (raises: []).} =
      onMessageReceived(e.messageHash),
  )
  discard MessageSeenEvent.listen(
    brokerCtx,
    proc(e: MessageSeenEvent) {.async: (raises: []).} =
      onNetworkMessage(string(e.topic), e.message),
  )
