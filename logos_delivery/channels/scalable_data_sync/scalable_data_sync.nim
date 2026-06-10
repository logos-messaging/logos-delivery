## Scalable Data Sync (SDS) component for the Reliable Channel API.
##
## `SdsHandler` adapts one nim-sds `ReliabilityManager` to a single channel:
## `wrapOutgoing` adds reliability metadata to outgoing segments,
## `handleIncoming` unwraps incoming ones and enforces causal-order delivery.
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
    ## Bound on segments parked while their causal dependencies are missing.

type
  SdsConfig* = object
    acknowledgementTimeoutMs*: int
    maxRetransmissions*: int
    causalHistorySize*: int
    persistence*: Option[Persistence]
      ## Durability backend. `none` runs memory-only: reliability still
      ## works, state does not survive a restart.

  ContentReadyHandler* = proc(content: seq[byte]) {.gcsafe, raises: [].}
    ## Invoked when SDS releases a parked segment (dependencies met).

  RebroadcastHandler* = proc(wire: seq[byte]) {.gcsafe, raises: [].}
    ## Invoked with a full SDS envelope to rebroadcast (SDS-R repair).

  SdsHandler* = ref object
    rm: ReliabilityManager
    channelId: SdsChannelID
    pendingContent: OrderedTable[SdsMessageID, seq[byte]]
      ## Segments parked until their causal dependencies arrive.
    onContentReady*: ContentReadyHandler
    onRebroadcast*: RebroadcastHandler

proc computeMessageId(payload: seq[byte]): SdsMessageID =
  ## Content-derived id: a retransmission of the same segment maps onto the
  ## same SDS message id and deduplicates instead of forking history.
  SdsMessageID(byteutils.toHex(sha256.digest(payload).data))

proc installCallbacks(self: SdsHandler) =
  ## Direct field assignment is race-free here: no periodic task or protocol
  ## op has started yet.
  self.rm.onMessageReady = proc(
      messageId: SdsMessageID, channelId: SdsChannelID
  ) {.gcsafe.} =
    ## Runs under the manager lock — must stay synchronous and non-blocking.
    if messageId in self.pendingContent:
      let content = self.pendingContent.getOrDefault(messageId)
      self.pendingContent.del(messageId)
      if not self.onContentReady.isNil():
        self.onContentReady(content)

  self.rm.onMessageSent = proc(
      messageId: SdsMessageID, channelId: SdsChannelID
  ) {.gcsafe.} =
    debug "SDS message acknowledged", channelId, messageId

  self.rm.onMissingDependencies = proc(
      messageId: SdsMessageID, missingDeps: seq[HistoryEntry], channelId: SdsChannelID
  ) {.gcsafe.} =
    ## Recovery via SDS sync / SDS-R for now; targeted store fetch by
    ## retrieval hint is a planned follow-up.
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
  let res = await self.rm.ensureChannel(self.channelId)
  if res.isErr():
    warn "SDS channel bootstrap failed; state will be restored lazily",
      channelId = self.channelId, error = $res.error

proc start*(self: SdsHandler) =
  ## Restores persisted channel state and starts the SDS background loops.
  asyncSpawn self.bootstrap()
  self.rm.startPeriodicTasks()

proc stop*(self: SdsHandler) {.async: (raises: []).} =
  ## Cancels the background loops. Persisted state is left intact.
  await self.rm.cleanup()

proc wrapOutgoing*(
    self: SdsHandler, payload: seq[byte]
): Future[Result[seq[byte], string]] {.async: (raises: []).} =
  ## Wraps a segment with reliability metadata and registers it in the SDS
  ## outgoing buffer awaiting end-to-end acknowledgement.
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
  ## Returns `ok(some(content))` when deliverable now, `ok(none)` when
  ## consumed by SDS (duplicate, foreign channel, sync traffic, or parked
  ## until dependencies arrive), `err` when not a decodable SDS envelope.
  let msg = deserializeMessage(wire).valueOr:
    return err("SDS deserialization failed")

  ## Pre-filter: `unwrapReceivedMessage` auto-creates the channel it sees on
  ## the wire, so foreign traffic must not reach it.
  if msg.channelId != self.channelId:
    debug "dropping SDS message for foreign channel",
      channelId = self.channelId, wireChannelId = msg.channelId
    return ok(none(seq[byte]))

  ## The unwrap result does not distinguish first delivery from duplicate,
  ## so capture delivered-before up front.
  let ctx = self.rm.channels.getOrDefault(self.channelId)
  let isDuplicate = not ctx.isNil() and msg.messageId in ctx.messageHistory

  let unwrapped = (await self.rm.unwrapReceivedMessage(wire)).valueOr:
    return err("SDS unwrap failed: " & $error)

  if isDuplicate:
    return ok(none(seq[byte]))

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
    return ok(none(seq[byte]))

  if unwrapped.message.len == 0:
    ## Sync traffic: causal metadata only, no app payload.
    return ok(none(seq[byte]))

  return ok(some(unwrapped.message))

{.pop.}
