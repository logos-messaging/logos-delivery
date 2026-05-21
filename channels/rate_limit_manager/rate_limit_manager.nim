## Rate Limit Manager for the Reliable Channel API.
##
## Tracks messages sent per RLN epoch and delays dispatch when the
## limit is approached, ensuring RLN compliance on enforcing relays.
##
## See: https://lip.logos.co/messaging/raw/reliable-channel-api.html

import std/times
import sds/message
import waku/common/broker/event_broker

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
  type ReadyToSendEvent* = object
    channelId*: SdsChannelID
    msgs*: seq[seq[byte]]

type
  RateLimitConfig* = object
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
  ## Stage 3 of the outgoing pipeline (segmentation -> sds -> rate_limit_manager -> encryption).
  ##
  ## For now: enqueue the message and immediately dequeue the full
  ## queue, emitting `ReadyToSendEvent` with the batch ready to be sent.
  ## TODO: park `msg` on `self.queue` and only emit when the RLN-epoch
  ## budget allows; advance epoch bookkeeping on `dequeueReady`.
  self.queue.add(msg)

  let ready = self.queue
  self.queue = @[]

  ReadyToSendEvent.emit(
    self.brokerCtx, ReadyToSendEvent(channelId: self.channelId, msgs: ready)
  )

proc dequeueReady*(self: RateLimitManager): seq[seq[byte]] =
  ## Returns the set of queued messages that may be dispatched now
  ## without exceeding the configured rate limit. Advances epoch
  ## bookkeeping as needed.
  discard

proc resetEpoch*(self: RateLimitManager) =
  self.currentEpochStart = getTime()
  self.sentInCurrentEpoch = 0
