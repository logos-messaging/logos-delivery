## The module's events, typed for the contract, and the mapping from the
## library's JSON event payloads onto them.
##
## In the module image the library's `emitEvent` lands here instead of in
## nim-ffi's event queue: the payload is decoded on the node's own thread and
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

proc str(j: JsonNode, key: string): string =
  let v = j.getOrDefault(key)
  return if v != nil and v.kind == JString: v.getStr() else: ""

proc payloadBytes(j: JsonNode, key: string): seq[byte] =
  ## message_received and channel_message_received carry base64 payloads.
  let s = str(j, key)
  if s.len == 0:
    return @[]
  try:
    return cast[seq[byte]](base64.decode(s))
  except CatchableError:
    return @[]

proc emitLibraryEventImpl(payloadJson: string) =
  var j: JsonNode
  try:
    j = parseJson(payloadJson)
  except CatchableError:
    return
  if j.kind != JObject:
    return
  let ts = nowNs()
  case str(j, "eventType")
  of "message_queued":
    messageQueued(str(j, "requestId"), str(j, "messageHash"), ts)
  of "message_sent":
    messageSent(str(j, "requestId"), str(j, "messageHash"), ts)
  of "message_error":
    messageError(str(j, "requestId"), str(j, "messageHash"), str(j, "error"), ts)
  of "message_propagated":
    messagePropagated(str(j, "requestId"), str(j, "messageHash"), ts)
  of "message_received":
    let msg = j.getOrDefault("message")
    let m = if msg != nil and msg.kind == JObject: msg else: newJObject()
    let msgTs = m.getOrDefault("timestamp")
    let t = if msgTs != nil and msgTs.kind in {JInt, JFloat}: int64(msgTs.getFloat()) else: 0'i64
    messageReceived(
      str(j, "messageHash"), str(m, "contentTopic"), payloadBytes(m, "payload"), str(j, "source"), t
    )
  of "node_started":
    nodeStarted(j.getOrDefault("success").getBool(false), str(j, "message"), ts)
  of "node_stopped":
    nodeStopped(j.getOrDefault("success").getBool(false), str(j, "message"), ts)
  of "connection_status_change":
    connectionStateChanged(str(j, "connectionStatus"), ts)
  of "channel_message_received":
    channelMessageReceived(
      str(j, "channelId"), str(j, "senderId"), payloadBytes(j, "payload"), ts
    )
  of "channel_message_sent":
    channelMessageSent(str(j, "channelId"), str(j, "requestId"), ts)
  of "channel_message_error":
    channelMessageError(str(j, "channelId"), str(j, "requestId"), str(j, "error"), ts)
  else:
    discard # events the module does not surface (topic health, connection change, ...)

proc emitLibraryEvent*(payloadJson: string) {.gcsafe, raises: [].} =
  ## One library event, by its `eventType`, onto the typed emitter. Called
  ## from the node's thread; the emitter reads the host's callback under the
  ## SDK's lock, which is what the gcsafe cast asserts.
  {.cast(gcsafe), cast(raises: []).}:
    emitLibraryEventImpl(payloadJson)

