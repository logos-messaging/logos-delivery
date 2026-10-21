## The events the library publishes to its host, as nim-ffi `{.ffiEvent.}`s.
##
## Each one carries a typed `{.ffi.}` payload, CBOR on the wire, so every
## generated binding gets a typed listener (C++: `addOn<Event>Listener`). The
## wire names are the ones the JSON events had, so the C listener registry
## (`logosdelivery_add_event_listener(ctx, "onMessageSent", ...)`) is unchanged;
## what changed is the payload: no `eventType` field, bytes as bytes instead of
## base64.
##
## An event proc is called from the node's broker listeners, which run on the
## FFI processing thread; nim-ffi queues it for its event thread to fan out.

import ffi
import
  logos_delivery,
  logos_delivery/api/types,
  logos_delivery/waku/waku_core/message/[message, digest],
  logos_delivery/waku/waku_core/topics/pubsub_topic,
  ../declare_lib

type
  WakuMessagePayload* {.ffi.} = object ## RFC 36's message, bytes as bytes.
    payload*: seq[byte]
    contentTopic*: string
    version*: uint32
    timestamp*: int64
    ephemeral*: bool
    meta*: seq[byte]
    proof*: seq[byte]

  MessageSentPayload* {.ffi.} = object
    requestId*: string
    messageHash*: string

  MessageErrorPayload* {.ffi.} = object
    requestId*: string
    messageHash*: string
    error*: string

  MessageQueuedPayload* {.ffi.} = object
    requestId*: string
    messageHash*: string

  MessagePropagatedPayload* {.ffi.} = object
    requestId*: string
    messageHash*: string

  MessageReceivedPayload* {.ffi.} = object
    messageHash*: string
    message*: WakuMessagePayload
    source*: string

  ConnectionStatusChangePayload* {.ffi.} = object
    connectionStatus*: string

  TopicHealthChangePayload* {.ffi.} = object
    pubsubTopic*: string
    topicHealth*: string

  ConnectionChangePayload* {.ffi.} = object
    peerId*: string
    peerEvent*: string

  ChannelMessageReceivedPayload* {.ffi.} = object
    channelId*: string
    senderId*: string
    payload*: seq[byte]

  ChannelMessageSentPayload* {.ffi.} = object
    channelId*: string
    requestId*: string

  ChannelMessageErrorPayload* {.ffi.} = object
    channelId*: string
    requestId*: string
    error*: string

  ChannelMessageLostPayload* {.ffi.} = object
    channelId*: string
    payloadHash*: string ## hex
    reason*: string

  ReceivedMessagePayload* {.ffi.} = object
    ## A kernel relay/filter delivery (RFC 36's JsonMessageEvent).
    pubsubTopic*: string
    messageHash*: string ## 0x hex
    wakuMessage*: WakuMessagePayload

proc onMessageSent*(p: MessageSentPayload) {.ffiEvent: "onMessageSent".}
proc onMessageError*(p: MessageErrorPayload) {.ffiEvent: "onMessageError".}
proc onMessageQueued*(p: MessageQueuedPayload) {.ffiEvent: "onMessageQueued".}
proc onMessagePropagated*(
  p: MessagePropagatedPayload
) {.ffiEvent: "onMessagePropagated".}

proc onMessageReceived*(p: MessageReceivedPayload) {.ffiEvent: "onMessageReceived".}
proc onConnectionStatusChange*(
  p: ConnectionStatusChangePayload
) {.ffiEvent: "onConnectionStatusChange".}

proc onTopicHealthChange*(
  p: TopicHealthChangePayload
) {.ffiEvent: "onTopicHealthChange".}

proc onConnectionChange*(p: ConnectionChangePayload) {.ffiEvent: "onConnectionChange".}
proc onChannelMessageReceived*(
  p: ChannelMessageReceivedPayload
) {.ffiEvent: "onChannelMessageReceived".}

proc onChannelMessageSent*(
  p: ChannelMessageSentPayload
) {.ffiEvent: "onChannelMessageSent".}

proc onChannelMessageError*(
  p: ChannelMessageErrorPayload
) {.ffiEvent: "onChannelMessageError".}

proc onChannelMessageLost*(
  p: ChannelMessageLostPayload
) {.ffiEvent: "onChannelMessageLost".}

proc onReceivedMessage*(p: ReceivedMessagePayload) {.ffiEvent: "onReceivedMessage".}

func toPayload*(msg: WakuMessage): WakuMessagePayload =
  WakuMessagePayload(
    payload: msg.payload,
    contentTopic: msg.contentTopic,
    version: msg.version,
    timestamp: int64(msg.timestamp),
    ephemeral: msg.ephemeral,
    meta: msg.meta,
    proof: msg.proof,
  )

proc receivedMessage*(
    pubsubTopic: PubsubTopic, msg: WakuMessage
): ReceivedMessagePayload =
  ReceivedMessagePayload(
    pubsubTopic: pubsubTopic,
    messageHash: computeMessageHash(pubsubTopic, msg).to0xHex(),
    wakuMessage: msg.toPayload(),
  )
