## FFI-facing event body types and converters.
##
## The in-process `EventBroker` event types (e.g. `MessageSentEvent`) carry
## domain types — `RequestId`, `WakuMessage`, `PeerId`, the `ConnectionStatus`
## enum — that don't have CBOR codecs out of the box. We mirror each event with
## a flat, CBOR-friendly body and convert at dispatch time, so the FFI wire
## format stays a stable schema of primitives + nested {.ffi.} maps.

import ffi
import libp2p/peerid
import
  logos_delivery/api/types,
  logos_delivery/api/events/messaging_client_events,
  logos_delivery/api/events/kernel_events,
  logos_delivery/api/events/reliable_channel_manager_events,
  logos_delivery/waku/api/events/health_events,
  logos_delivery/waku/api/events/peer_events,
  logos_delivery/waku/waku_core/message,
  logos_delivery/waku/waku_core/topics/pubsub_topic

type
  MessageSentBody* {.ffi.} = object
    requestId*: string
    messageHash*: string

  MessageErrorBody* {.ffi.} = object
    requestId*: string
    messageHash*: string
    error*: string

  MessagePropagatedBody* {.ffi.} = object
    requestId*: string
    messageHash*: string

  WakuMessageBody* {.ffi.} = object
    payload*: seq[byte]
    contentTopic*: string
    meta*: seq[byte]
    version*: uint32
    timestamp*: int64
    ephemeral*: bool
    proof*: seq[byte]

  MessageReceivedBody* {.ffi.} = object
    messageHash*: string
    message*: WakuMessageBody

  ## Relay / filter push: the raw kernel-level message delivery.
  RelayMessageBody* {.ffi.} = object
    pubsubTopic*: string
    messageHash*: string
    message*: WakuMessageBody

  ConnectionStatusChangeBody* {.ffi.} = object
    connectionStatus*: string

  TopicHealthChangeBody* {.ffi.} = object
    pubsubTopic*: string
    topicHealth*: string

  ConnectionChangeBody* {.ffi.} = object
    peerId*: string
    peerEvent*: string

  ChannelMessageReceivedBody* {.ffi.} = object
    channelId*: string
    senderId*: string
    payload*: seq[byte]

  ChannelMessageSentBody* {.ffi.} = object
    channelId*: string
    requestId*: string

  ChannelMessageErrorBody* {.ffi.} = object
    channelId*: string
    requestId*: string
    error*: string

proc toFfi*(e: MessageSentEvent): MessageSentBody =
  MessageSentBody(requestId: $e.requestId, messageHash: e.messageHash)

proc toFfi*(e: MessageErrorEvent): MessageErrorBody =
  MessageErrorBody(requestId: $e.requestId, messageHash: e.messageHash, error: e.error)

proc toFfi*(e: MessagePropagatedEvent): MessagePropagatedBody =
  MessagePropagatedBody(requestId: $e.requestId, messageHash: e.messageHash)

proc toFfi*(m: WakuMessage): WakuMessageBody =
  WakuMessageBody(
    payload: m.payload,
    contentTopic: m.contentTopic,
    meta: m.meta,
    version: m.version,
    timestamp: int64(m.timestamp),
    ephemeral: m.ephemeral,
    proof: m.proof,
  )

proc toFfi*(e: MessageReceivedEvent): MessageReceivedBody =
  MessageReceivedBody(messageHash: e.messageHash, message: toFfi(e.message))

proc toRelayMessageBody*(pubsubTopic: PubsubTopic, msg: WakuMessage): RelayMessageBody =
  RelayMessageBody(
    pubsubTopic: string(pubsubTopic),
    messageHash: computeMessageHash(pubsubTopic, msg).to0xHex(),
    message: toFfi(msg),
  )

proc toFfi*(e: EventConnectionStatusChange): ConnectionStatusChangeBody =
  ConnectionStatusChangeBody(connectionStatus: $e.connectionStatus)

proc toFfi*(e: EventShardTopicHealthChange): TopicHealthChangeBody =
  TopicHealthChangeBody(pubsubTopic: $e.topic, topicHealth: $e.health)

proc toFfi*(e: WakuPeerEvent): ConnectionChangeBody =
  ConnectionChangeBody(peerId: $e.peerId, peerEvent: $e.kind)

proc toFfi*(e: ChannelMessageReceivedEvent): ChannelMessageReceivedBody =
  ChannelMessageReceivedBody(
    channelId: string(e.channelId), senderId: $e.senderId, payload: e.payload
  )

proc toFfi*(e: ChannelMessageSentEvent): ChannelMessageSentBody =
  ChannelMessageSentBody(channelId: string(e.channelId), requestId: $e.requestId)

proc toFfi*(e: ChannelMessageErrorEvent): ChannelMessageErrorBody =
  ChannelMessageErrorBody(
    channelId: string(e.channelId), requestId: $e.requestId, error: e.error
  )
