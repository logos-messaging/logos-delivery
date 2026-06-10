## Scalable Data Sync (SDS) component for the Reliable Channel API.
##
## Provides end-to-end delivery guarantees via causal history tracking,
## acknowledgements, and retransmission of unacknowledged segments.
##
## `SdsHandler` adapts one nim-sds `ReliabilityManager` to a single
## channel of the Reliable Channel pipeline:
##
##   outgoing: `wrapOutgoing` adds causal history / lamport timestamp /
##             bloom filter to each encoded segment.
##   incoming: `handleIncoming` unwraps the SDS envelope; segments whose
##             causal dependencies are met are returned for immediate
##             delivery, the rest are parked until SDS releases them via
##             `onContentReady`.
##
## Message ids are content-derived (SHA-256 of the segment bytes), so a
## retransmission of the same segment maps onto the same SDS message id
## and deduplicates instead of forking history.
##
## See: https://lip.logos.co/messaging/raw/reliable-channel-api.html
## SDS spec (IFT LIP-109): https://lip.logos.co/ift-ts/raw/sds.html

{.push raises: [].}

import std/[options, tables]
import results, chronos, chronicles
import nimcrypto/sha2
import stew/byteutils
from std/times import initDuration

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
  MaxPendingContent = 1024
    ## Upper bound on segments parked while their causal dependencies are
    ## missing. SDS keeps its own (unbounded) incoming buffer; this cap only
    ## protects the content stash from a peer that never closes its gaps.

type
  SdsConfig* = object
    acknowledgementTimeoutMs*: int
    maxRetransmissions*: int
    causalHistorySize*: int
    persistence*: Option[Persistence]
      ## Durability backend for SDS state (nim-sds contract). `none` runs
      ## memory-only: reliability still works, state does not survive a
      ## restart.

  ContentReadyHandler* = proc(content: seq[byte]) {.gcsafe, raises: [].}
    ## Invoked when SDS releases a previously-parked segment (all causal
    ## dependencies met). The channel routes it into reassembly, the same
    ## path `handleIncoming` results take.

  RebroadcastHandler* = proc(wire: seq[byte]) {.gcsafe, raises: [].}
    ## Invoked when SDS-R asks us to rebroadcast a message we hold (repair
    ## response). `wire` is a full SDS envelope, ready for the
    ## encrypt -> dispatch tail of the egress pipeline.

  SdsHandler* = ref object
    rm: ReliabilityManager
    channelId: SdsChannelID
    pendingContent: OrderedTable[SdsMessageID, seq[byte]]
      ## Segments unwrapped but undeliverable until their causal
      ## dependencies arrive. Keyed by SDS message id; released by the
      ## `onMessageReady` callback. Insertion-ordered so the cap evicts
      ## the longest-waiting entry first.
    onContentReady*: ContentReadyHandler
    onRebroadcast*: RebroadcastHandler

proc computeMessageId(payload: seq[byte]): SdsMessageID =
  SdsMessageID(byteutils.toHex(sha256.digest(payload).data))

proc installCallbacks(self: SdsHandler) =
  ## Direct field assignment instead of the async `setCallbacks` API: the
  ## manager was created moments ago on this same event loop and no periodic
  ## task or protocol op has started yet, so there is nothing to race with.
  self.rm.onMessageReady = proc(
      messageId: SdsMessageID, channelId: SdsChannelID
  ) {.gcsafe.} =
    ## Fired (under the manager lock) when a buffered message's dependencies
    ## are all met. Must stay synchronous and non-blocking.
    if messageId in self.pendingContent:
      let content = self.pendingContent.getOrDefault(messageId)
      self.pendingContent.del(messageId)
      if not self.onContentReady.isNil():
        self.onContentReady(content)

  self.rm.onMessageSent = proc(
      messageId: SdsMessageID, channelId: SdsChannelID
  ) {.gcsafe.} =
    ## End-to-end acknowledgement: peers' causal history / bloom filter
    ## covered this outgoing message (or retransmission attempts were
    ## exhausted). Not surfaced as a channel event yet.
    debug "SDS message acknowledged", channelId, messageId

  self.rm.onMissingDependencies = proc(
      messageId: SdsMessageID, missingDeps: seq[HistoryEntry], channelId: SdsChannelID
  ) {.gcsafe.} =
    ## Recovery is left to SDS periodic sync / SDS-R repair and the
    ## delivery-service store sweep. A targeted store fetch by retrieval
    ## hint is the planned follow-up to this integration.
    debug "SDS message has missing dependencies",
      channelId, messageId, missing = missingDeps.len

  self.rm.onRepairReady = proc(message: seq[byte], channelId: SdsChannelID) {.gcsafe.} =
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
    rm: rm,
    channelId: channelId,
    pendingContent: initOrderedTable[SdsMessageID, seq[byte]](),
  )
  handler.installCallbacks()
  return handler

proc bootstrap(self: SdsHandler) {.async: (raises: []).} =
  ## Eager warm-up: restore persisted state (meta + history, bloom rebuilt)
  ## before traffic flows. Failure is non-fatal — every protocol op goes
  ## through `getOrCreateChannel` and retries the load lazily.
  let res = await self.rm.ensureChannel(self.channelId)
  if res.isErr():
    warn "SDS channel bootstrap failed; state will be restored lazily",
      channelId = self.channelId, error = $res.error

proc start*(self: SdsHandler) =
  ## Restores persisted channel state and starts the SDS background loops
  ## (unacknowledged-message sweep, periodic sync, SDS-R repair sweep).
  asyncSpawn self.bootstrap()
  self.rm.startPeriodicTasks()

proc stop*(self: SdsHandler) {.async: (raises: []).} =
  ## Cancels the background loops and releases in-memory state. Persisted
  ## state is left intact for the next `start`.
  await self.rm.cleanup()

proc wrapOutgoing*(
    self: SdsHandler, payload: seq[byte]
): Future[Result[seq[byte], string]] {.async: (raises: []).} =
  ## Stage 2 of the outgoing pipeline (segmentation -> sds -> rate_limit_manager
  ## -> encryption). Registers the segment in the SDS outgoing buffer (awaiting
  ## end-to-end acknowledgement) and returns the SDS envelope to dispatch.
  let wrapped = (
    await self.rm.wrapOutgoingMessage(
      payload, computeMessageId(payload), self.channelId
    )
  ).valueOr:
    return err("SDS wrap failed: " & $error)
  return ok(wrapped)

proc handleIncoming*(
    self: SdsHandler, wire: seq[byte]
): Future[Result[Option[seq[byte]], string]] {.async: (raises: []).} =
  ## Stage 2 of the ingress pipeline (decrypt -> sds -> reassemble). Returns:
  ##  * `ok(some(content))` — deliverable now (causal dependencies met),
  ##  * `ok(none)` — consumed by SDS: duplicate, foreign channel, sync
  ##    traffic without app payload, or parked until dependencies arrive
  ##    (released later through `onContentReady`),
  ##  * `err` — not a decodable SDS envelope; the caller drops it.
  let msg = deserializeMessage(wire).valueOr:
    return err("SDS deserialization failed")

  ## Pre-filter before unwrapping: `unwrapReceivedMessage` auto-creates the
  ## channel it sees on the wire, so feeding it foreign traffic would
  ## materialise (and persist) spurious channels in this manager.
  if msg.channelId != self.channelId:
    debug "dropping SDS message for foreign channel",
      channelId = self.channelId, wireChannelId = msg.channelId
    return ok(none(seq[byte]))

  ## The unwrap result does not distinguish first delivery from duplicate,
  ## so capture delivered-before up front. Duplicates still go through
  ## `unwrapReceivedMessage`: it cancels pending SDS-R repairs and retries
  ## any queued persistence writes on that path.
  let ctx = self.rm.channels.getOrDefault(self.channelId)
  let isDuplicate = not ctx.isNil() and msg.messageId in ctx.messageHistory

  let unwrapped = (await self.rm.unwrapReceivedMessage(wire)).valueOr:
    return err("SDS unwrap failed: " & $error)

  if isDuplicate:
    return ok(none(seq[byte]))

  if unwrapped.missingDeps.len > 0:
    ## SDS buffered the message; park the content until `onMessageReady`.
    if self.pendingContent.len >= MaxPendingContent:
      var oldest: SdsMessageID
      for k in self.pendingContent.keys:
        oldest = k
        break
      self.pendingContent.del(oldest)
      warn "SDS pending-content stash full, dropping oldest entry",
        channelId = self.channelId, dropped = oldest
    self.pendingContent[msg.messageId] = unwrapped.message
    return ok(none(seq[byte]))

  if unwrapped.message.len == 0:
    ## Sync / heartbeat traffic: causal metadata only, no app payload.
    return ok(none(seq[byte]))

  return ok(some(unwrapped.message))

{.pop.}
