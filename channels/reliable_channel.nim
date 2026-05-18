## Reliable Channel type.
##
## A `ReliableChannel` orchestrates segmentation, SDS (end-to-end
## reliability), optional encryption, and rate-limited dispatch on top
## of the Messaging API for a single channel.
##
## Outgoing pipeline: Segment -> SDS -> Rate Limit -> Encrypt -> Dispatch
## Incoming pipeline: Decrypt -> SDS -> Reassemble -> Emit event
##
## Channels are owned by a `ReliableChannelManager`. Lifecycle and send
## operations are addressed by `ChannelId`, so callers only need to keep
## an opaque handle around.
##
## See: https://lip.logos.co/messaging/raw/reliable-channel-api.html

import ./events
import ./segmentation/segmentation
import ./scalable_data_sync/scalable_data_sync
import ./rate_limit_manager/rate_limit_manager
import ./encryption/encryption

export events, segmentation, scalable_data_sync, rate_limit_manager, encryption

type
  ContentTopic* = string

  WakuNode* = ref object
    ## Opaque handle to the underlying messaging node. The node's
    ## NodeConfig carries `segmentation_config`, `sds_config` and
    ## `rate_limit_config` consumed by the Reliable Channel layer.
    ## TODO: replace with `waku/node/waku_node.WakuNode` once wired up.
    segmentationConfig*: SegmentationConfig
    sdsConfig*: SdsConfig
    rateLimitConfig*: RateLimitConfig

  ReliablePayload* = object
    channelId*: ChannelId
    payload*: seq[byte]

  MessageEnvelope* = object
    contentTopic*: ContentTopic
    payload*: seq[byte]
    ephemeral*: bool

  ReliableChannel* = ref object
    node*: WakuNode
    channelId*: ChannelId
    contentTopic*: ContentTopic
    senderId*: SdsParticipantID
    segmentation*: SegmentationHandler
    sds*: SdsHandler
    rateLimit*: RateLimitManager
    encryption*: EncryptionHook
