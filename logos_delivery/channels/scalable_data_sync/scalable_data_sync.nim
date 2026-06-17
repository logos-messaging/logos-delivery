## Scalable Data Sync (SDS) component for the Reliable Channel API.
##
## `SdsHandler` adapts one nim-sds `ReliabilityManager` to a single channel:
## `wrapOutgoing` adds reliability metadata to outgoing segments,
## `handleIncoming` unwraps incoming ones and enforces causal-order delivery.
##
## See: https://lip.logos.co/messaging/raw/reliable-channel-api.html

{.push raises: [].}

import std/[options, tables]
from std/times import initDuration, getTime, toUnix, nanosecond
import results, chronos, chronicles
import nimcrypto/keccak
import stew/byteutils

import sds
import message as sds_message
import types/persistence as sds_persistence_types

export sds_message, sds_persistence_types

logScope:
  topics = "sds-handler"

const
  DefaultAcknowledgementTimeoutMs* = 5_000
  DefaultMaxRetransmissions* = 5
  DefaultCausalHistorySize* = 2
  MaxPendingContent = 32
    ## Bound on segments parked while their causal dependencies are missing.
    ## Kept small on purpose: at ~100KiB max per segment, 32 caps the stash
    ## at ~3MiB per channel. Raise only if a real backlog need shows up.

type
  SdsConfig* = object
    acknowledgementTimeoutMs*: int
    maxRetransmissions*: int
    causalHistorySize*: int
    persistence*: Option[Persistence]
      ## Durability backend. `none` runs memory-only: reliability still
      ## works, state does not survive a restart.

  RebroadcastHandler* = proc(wire: seq[byte]) {.gcsafe, raises: [].}
    ## Invoked with a full SDS envelope to rebroadcast (SDS-R repair).

  SdsHandler* = ref object
    reliabilityManager: ReliabilityManager
    channelId: SdsChannelID
    pendingContent: OrderedTable[SdsMessageID, seq[byte]]
      ## Segments parked until their causal dependencies arrive.
    released: seq[seq[byte]]
      ## Parked segments released by the unwrap currently in flight;
      ## filled via `onMessageReady`, drained by `handleIncoming`.
    ingressLock: AsyncLock
      ## Serializes `handleIncoming` so `released` belongs to exactly one
      ## in-flight unwrap and delivery order stays causal.
    participantId: SdsParticipantID
    onRebroadcast*: RebroadcastHandler
      ## Set by the owning `ReliableChannel` after construction — the closure
      ## captures the channel to run its dispatch tail, so it cannot be
      ## passed to `new`. The other callbacks need no channel and are wired
      ## internally in `installCallbacks`.

proc computeMessageId(self: SdsHandler, payload: seq[byte]): SdsMessageID =
  ## keccak-256(senderId + wrap-time nanoseconds + content): unique per
  ## segment, so identical content is not collapsed by the SDS dedup.
  let now = getTime()
  var ctx: keccak256
  ctx.init()
  ctx.update(string(self.participantId))
  ctx.update($(now.toUnix() * 1_000_000_000 + now.nanosecond()))
  ctx.update(payload)
  SdsMessageID(byteutils.toHex(ctx.finish().data))

proc installCallbacks(self: SdsHandler) =
  ## Direct field assignment is race-free here: no periodic task or protocol
  ## op has started yet.
  self.reliabilityManager.onMessageReady = proc(
      messageId: SdsMessageID, channelId: SdsChannelID
  ) {.gcsafe.} =
    ## An SDS "message" is one channel segment here — each segment is wrapped
    ## into its own SDS message — so this is effectively `onSegmentReady`.
    ## Fires during unwrap, under the manager lock — must stay synchronous.
    ## Collect only; `handleIncoming` delivers after the direct content.
    ## The manager owns a single channel, so `channelId` is always ours; the
    ## check documents that invariant and guards against future misuse.
    if channelId == self.channelId and messageId in self.pendingContent:
      debug "SDS releasing buffered message, dependencies met", channelId, messageId
      self.released.add(self.pendingContent.getOrDefault(messageId))
      self.pendingContent.del(messageId)

  self.reliabilityManager.onMessageSent = proc(
      messageId: SdsMessageID, channelId: SdsChannelID
  ) {.gcsafe.} =
    debug "SDS message acknowledged", channelId, messageId

  self.reliabilityManager.onMissingDependencies = proc(
      messageId: SdsMessageID, missingDeps: seq[HistoryEntry], channelId: SdsChannelID
  ) {.gcsafe.} =
    ## Recovery via SDS sync / SDS-R for now; targeted store fetch by
    ## retrieval hint is a planned follow-up.
    debug "SDS message has missing dependencies",
      channelId, messageId, missing = missingDeps.len

  self.reliabilityManager.onRepairReady = proc(
      message: seq[byte], channelId: SdsChannelID
  ) {.gcsafe.} =
    if not self.onRebroadcast.isNil():
      self.onRebroadcast(message)

proc new*(
    T: type SdsHandler,
    config: SdsConfig,
    channelId: SdsChannelID,
    participantId: SdsParticipantID,
): T =
  ## One `ReliabilityManager` per channel. `participantId` feeds SDS-R
  ## response groups; an empty id disables repair participation.
  let reliabilityConfig = ReliabilityConfig.init(
    maxCausalHistory = config.causalHistorySize,
    resendInterval = initDuration(milliseconds = config.acknowledgementTimeoutMs),
    maxResendAttempts = config.maxRetransmissions,
  )
  let rm = ReliabilityManager.new(
    participantId, reliabilityConfig, config.persistence.get(noOpPersistence())
  )
  let handler = T(
    reliabilityManager: rm,
    channelId: channelId,
    pendingContent: initOrderedTable[SdsMessageID, seq[byte]](),
    released: @[],
    ingressLock: newAsyncLock(),
    participantId: participantId,
  )
  handler.installCallbacks()
  return handler

proc start*(self: SdsHandler) =
  ## Starts the SDS background loops. Persisted channel state is restored
  ## lazily on first use: `wrapOutgoing` and `handleIncoming` both ensure
  ## the channel, and `handleIncoming` loads before its duplicate check so a
  ## replay right after a restart is still caught.
  self.reliabilityManager.startPeriodicTasks()

proc stop*(self: SdsHandler) {.async: (raises: []).} =
  ## Cancels the background loops. Persisted state is left intact.
  await self.reliabilityManager.cleanup()

proc wrapOutgoing*(
    self: SdsHandler, payload: seq[byte]
): Future[Result[seq[byte], string]] {.async: (raises: []).} =
  ## Wraps a segment with reliability metadata and registers it in the SDS
  ## outgoing buffer awaiting end-to-end acknowledgement.
  let wrapped = (
    await self.reliabilityManager.wrapOutgoingMessage(
      payload, self.computeMessageId(payload), self.channelId
    )
  ).valueOr:
    return err("SDS wrap failed: " & $error)
  return ok(wrapped)

proc handleIncoming*(
    self: SdsHandler, wire: seq[byte]
): Future[Result[seq[seq[byte]], string]] {.async: (raises: []).} =
  ## Returns the payloads deliverable now, in causal order. Empty when SDS
  ## consumed the message; `err` when the bytes are not an SDS envelope.
  let msg = deserializeMessage(wire).valueOr:
    return err("SDS deserialization failed: " & $error)

  ## Pre-filter: `unwrapReceivedMessage` auto-creates the channel it sees on
  ## the wire, so foreign traffic must not reach it.
  if msg.channelId != self.channelId:
    debug "dropping SDS message for foreign channel",
      channelId = self.channelId, wireChannelId = msg.channelId
    return ok(newSeq[seq[byte]]())

  ## Only the lock acquisition can raise (CancelledError); the unwrap work
  ## below is `raises: []`, so the try stays scoped to exactly the acquire.
  try:
    await self.ingressLock.acquire()
  except CancelledError:
    return err("SDS handleIncoming cancelled before acquiring ingress lock")

  ## Funnel every unwrap outcome into `res` so the lock is released once on
  ## the tail path, where `releaseIngressLock` can surface its own error.
  var res: Result[seq[seq[byte]], string]
  block ingress:
    ## Load persisted state before the duplicate check, so a replay right
    ## after a restart is not re-delivered. Idempotent, cheap once loaded.
    (await self.reliabilityManager.ensureChannel(self.channelId)).isOkOr:
      res = err("SDS ensureChannel failed: " & $error)
      break ingress

    ## The unwrap result does not distinguish first delivery from
    ## duplicate, so capture delivered-before up front.
    let ctx = self.reliabilityManager.channels.getOrDefault(self.channelId)
    let isDuplicate = not ctx.isNil() and msg.messageId in ctx.messageHistory

    self.released.setLen(0)
    let unwrapped = (await self.reliabilityManager.unwrapReceivedMessage(wire)).valueOr:
      res = err("SDS unwrap failed: " & $error)
      break ingress

    if isDuplicate:
      res = ok(newSeq[seq[byte]]())
      break ingress

    if unwrapped.missingDeps.len > 0:
      if self.pendingContent.len >= MaxPendingContent:
        var oldest: SdsMessageID
        for k in self.pendingContent.keys:
          oldest = k
          break
        self.pendingContent.del(oldest)
        warn "SDS pending-content stash full, dropping oldest entry",
          channelId = self.channelId, dropped = oldest
      self.pendingContent[msg.messageId] = unwrapped.message
      res = ok(newSeq[seq[byte]]())
      break ingress

    var deliverable = newSeq[seq[byte]]()
    if unwrapped.message.len > 0:
      ## Empty content is sync traffic: causal metadata only.
      deliverable.add(unwrapped.message)
    deliverable.add(self.released)
    self.released.setLen(0)
    res = ok(deliverable)

  try:
    self.ingressLock.release()
  except AsyncLockError as e:
    return err("SDS ingress lock release failed: " & e.msg)

  return res

{.pop.}
