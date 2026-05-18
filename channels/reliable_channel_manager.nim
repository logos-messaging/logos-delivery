## Reliable Channel API entry point.
##
## Owns the set of `ReliableChannel` instances and exposes lifecycle and
## send/receive operations addressed by `ChannelId`.
##
## See: https://lip.logos.co/messaging/raw/reliable-channel-api.html

import std/[options, tables]
import results

import ./reliable_channel
import ./encryption/encryption
import ./encryption/noop_encryption

export reliable_channel

type ReliableChannelManager* = ref object
  channels: Table[ChannelId, ReliableChannel]

proc new*(T: type ReliableChannelManager): T =
  T(channels: initTable[ChannelId, ReliableChannel]())

proc createReliableChannel*(
    manager: ReliableChannelManager,
    node: WakuNode,
    channelId: ChannelId,
    contentTopic: ContentTopic,
    senderId: SdsParticipantID,
    encryption: Option[EncryptionHook] = none(EncryptionHook),
): Result[ChannelId, string] =
  ## Spec: createReliableChannel(node, channelId, contentTopic, senderId, encryption?)
  ## Segmentation, SDS and rate-limit configs are taken from the node's NodeConfig.
  if manager.channels.hasKey(channelId):
    return err("channel already exists: " & channelId)

  let enc =
    if encryption.isSome and encryption.get.isConfigured():
      encryption.get
    else:
      newNoopEncryptionHook()
  let chn = ReliableChannel(
    node: node,
    channelId: channelId,
    contentTopic: contentTopic,
    senderId: senderId,
    segmentation: SegmentationHandler.new(node.segmentationConfig),
    sds: SdsHandler.new(node.sdsConfig),
    rateLimit: RateLimitManager.new(node.rateLimitConfig),
    encryption: enc,
  )
  manager.channels[channelId] = chn
  return ok(channelId)

proc closeChannel*(
    manager: ReliableChannelManager, channelId: ChannelId
): Result[void, string] =
  ## Flush state, persist outstanding SDS buffers, release resources.
  if not manager.channels.hasKey(channelId):
    return err("unknown channel: " & channelId)
  manager.channels.del(channelId)
  return ok()

proc send*(
    manager: ReliableChannelManager,
    channelId: ChannelId,
    appPayload: seq[byte],
    ephemeral: bool = false,
): Result[RequestId, string] =
  ## Single application-level send. Internally produces one or more
  ## segment-level dispatches; the returned RequestId maps to all of them.
  let chn = manager.channels.getOrDefault(channelId)
  if chn.isNil():
    return err("unknown channel: " & channelId)

  let segments = chn.segmentation.segmentMessage(appPayload)
  for segment in segments:
    let sdsMsg = chn.sds.wrapOutgoing(chn.channelId, chn.senderId, segment.payload)
    chn.rateLimit.enqueue(sdsMsg)

  return ok()

proc processSendQueue*(manager: ReliableChannelManager, channelId: ChannelId) =
  ## Drain ready messages from the rate limiter and dispatch them via
  ## the underlying Messaging API.
  let chn = manager.channels.getOrDefault(channelId)
  if chn.isNil():
    return
  let ready = chn.rateLimit.dequeueReady()
  for sdsMsg in ready:
    discard sdsMsg
    ## TODO: encrypt(sdsMsg payload) -> wrap as ReliablePayload -> WakuMessage

proc processInboundMessage*(
    manager: ReliableChannelManager, channelId: ChannelId, inMsg: MessageEnvelope
) =
  ## Entry point for messages delivered by the Messaging API.
  ##
  ## TODO:
  ## - validate LIP173 meta on the WakuMessage
  ## - decode `ReliablePayload`
  ## - decrypt via chn.encryption
  ## - feed into chn.sds.handleIncoming
  ## - feed resulting segment into chn.segmentation.handleIncomingSegment
  ## - on reassembly completion, emit MessageReceivedEvent
  discard
