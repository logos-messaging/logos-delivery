## Rate Limit Manager for the Reliable Channel API.
##
## Tracks messages sent per RLN epoch and delays dispatch when the
## limit is approached, ensuring RLN compliance on enforcing relays.
##
## For the skeleton this is a pass-through: messages are immediately
## released as ready-to-send. Real epoch budgeting will be added later.
##
## See: https://lip.logos.co/messaging/raw/reliable-channel-api.html

import std/times
import message
import brokers/event_broker
import brokers/broker_context

export event_broker, broker_context
export message.SdsChannelID

const
  DefaultEpochPeriodSec* = 600
  DefaultMessagesPerEpoch* = 1

EventBroker:
  ## Emitted by `enqueueToSend` carrying the batch of opaque message
  ## blobs that may now leave the rate limiter and continue down the
  ## outgoing pipeline (encryption -> dispatch). Bytes only: the rate
  ## limiter is intentionally agnostic of SDS, so anything serialisable
  ## can flow through it.
  ##
  ## `channelId` lets listeners filter to their own channel, since all
  ## reliable channels share the underlying Waku node's broker context.
  type ReadyToSendEvent* = ref object
    channelId*: SdsChannelID
    msgs*: seq[seq[byte]]

type
  RateLimitConfig* = object
    enabled*: bool ## spec: rate limiting opt-in; SHOULD be true when RLN active
    epochPeriodSec*: int
    messagesPerEpoch*: int

  RateLimitManager* = ref object
    config*: RateLimitConfig
    queue*: seq[seq[byte]]
    currentEpochStart*: Time
    sentInCurrentEpoch*: int
    channelId*: SdsChannelID ## tag for the emitted `ReadyToSendEvent`
    brokerCtx: BrokerContext

proc new*(
    T: type RateLimitManager,
    config: RateLimitConfig,
    channelId: SdsChannelID,
    brokerCtx: BrokerContext = globalBrokerContext(),
): T =
  return T(
    config: config,
    queue: @[],
    currentEpochStart: getTime(),
    sentInCurrentEpoch: 0,
    channelId: channelId,
    brokerCtx: brokerCtx,
  )

proc enqueueToSend*(self: RateLimitManager, msg: seq[byte]) =
  ## Skeleton behaviour: enqueue and immediately release as a single
  ## ready batch. Real per-epoch budgeting will park messages on
  ## `self.queue` and emit only when the budget allows.
  ReadyToSendEvent.emit(
    self.brokerCtx, ReadyToSendEvent(channelId: self.channelId, msgs: @[msg])
  )

proc dequeueReady*(self: RateLimitManager): seq[seq[byte]] =
  ## Returns the set of queued messages that may be dispatched now
  ## without exceeding the configured rate limit.
  discard

proc resetEpoch*(self: RateLimitManager) =
  self.currentEpochStart = getTime()
  self.sentInCurrentEpoch = 0
