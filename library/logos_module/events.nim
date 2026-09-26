## The module's events, typed for the contract, and the mapping from the
## library's JSON event payloads onto them.
##
## In the module image nim-ffi hands each event here as it is emitted
## (`setFFIEventSink`): the payload is decoded on the node's own thread and
## handed to the host's emit callback at once ("the emit callback may be
## invoked from any module thread; the host marshals"). No queue, no thread.

import std/[base64, json, times]
import logos_sdk

proc messageQueued(requestId, messageHash: string, timestamp: int64) {.logosEventAs: "messageQueued".}
proc messageSent(requestId, messageHash: string, timestamp: int64) {.logosEventAs: "messageSent".}
proc messageError(requestId, messageHash, error: string, timestamp: int64) {.logosEventAs: "messageError".}
proc messagePropagated(requestId, messageHash: string, timestamp: int64) {.logosEventAs: "messagePropagated".}
proc messageReceived(
  messageHash, contentTopic: string, payload: seq[byte], source: string, timestamp: int64
) {.logosEventAs: "messageReceived".}
proc connectionStateChanged(connectionStatus: string, timestamp: int64) {.logosEventAs: "connectionStateChanged".}
proc channelMessageReceived(
  channelId, senderId: string, payload: seq[byte], timestamp: int64
) {.logosEventAs: "channelMessageReceived".}
proc channelMessageSent(channelId, requestId: string, timestamp: int64) {.logosEventAs: "channelMessageSent".}
proc channelMessageError(channelId, requestId, error: string, timestamp: int64) {.logosEventAs: "channelMessageError".}
proc nodeStarted*(success: bool, message: string, timestamp: int64) {.logosEventAs: "nodeStarted".}
proc nodeStopped*(success: bool, message: string, timestamp: int64) {.logosEventAs: "nodeStopped".}
proc rlnStateChanged*(state, message: string, timestamp: int64) {.logosEventAs: "rlnStateChanged".}
proc dispatchRlnGetMembershipStateRequestEvent*(
  reqId: int64, registryId, rlnIdentifier: string, timestamp: int64
) {.logosEventAs: "dispatchRlnGetMembershipStateRequestEvent".}
proc dispatchRlnGetEpochQuotaRequestEvent*(
  reqId: int64, registryId, rlnIdentifier: string, epochTimestamp, timestamp: int64
) {.logosEventAs: "dispatchRlnGetEpochQuotaRequestEvent".}
proc dispatchRlnGenerateProofRequestEvent*(
  reqId: int64, registryId, rlnIdentifier, signalHex: string, epochTimestamp, timestamp: int64
) {.logosEventAs: "dispatchRlnGenerateProofRequestEvent".}
proc dispatchRlnValidateProofRequestEvent*(
  reqId: int64,
  registryId, rlnIdentifier, signalHex: string,
  epochTimestamp: int64,
  proofJson: string,
  timestamp: int64,
) {.logosEventAs: "dispatchRlnValidateProofRequestEvent".}

proc nowNs*(): int64 =
  return int64(epochTime() * 1e9)

proc bytes(j: JsonNode): seq[byte] =
  ## A base64 payload, as message_received and channel_message_received carry it.
  try:
    return cast[seq[byte]](base64.decode(j.getStr("")))
  except CatchableError:
    return @[]

proc route(j: JsonNode) =
  ## One library event, by its `eventType`, onto the contract's event.
  template s(key: string): string = j{key}.getStr("")
  let ts = nowNs()
  case s"eventType"
  of "message_queued": messageQueued(s"requestId", s"messageHash", ts)
  of "message_sent": messageSent(s"requestId", s"messageHash", ts)
  of "message_error": messageError(s"requestId", s"messageHash", s"error", ts)
  of "message_propagated": messagePropagated(s"requestId", s"messageHash", ts)
  of "message_received":
    let m = j{"message"}
    messageReceived(
      s"messageHash", m{"contentTopic"}.getStr(""), bytes(m{"payload"}), s"source",
      int64(m{"timestamp"}.getFloat(0)),
    )
  of "node_started": nodeStarted(j{"success"}.getBool(false), s"message", ts)
  of "node_stopped": nodeStopped(j{"success"}.getBool(false), s"message", ts)
  of "connection_status_change": connectionStateChanged(s"connectionStatus", ts)
  of "channel_message_received":
    channelMessageReceived(s"channelId", s"senderId", bytes(j{"payload"}), ts)
  of "channel_message_sent": channelMessageSent(s"channelId", s"requestId", ts)
  of "channel_message_error": channelMessageError(s"channelId", s"requestId", s"error", ts)
  else: discard # events the contract does not surface (topic health, ...)

proc emitLibraryEvent*(payloadJson: string) {.gcsafe, raises: [].} =
  ## Called from the node's thread; the emitter reads the host's callback
  ## under the SDK's lock, which is what the gcsafe cast asserts.
  {.cast(gcsafe), cast(raises: []).}:
    try:
      let j = parseJson(payloadJson)
      if j.kind == JObject:
        route(j)
    except CatchableError:
      discard

