## logos-delivery as a Logos Core module, in one image: liblogosdelivery's
## nim-ffi exports plus the `logos_module_*` exports logos-core's plugin glue
## calls. Three parts and nothing between them: logos-core (which carries
## every call between modules), this, and the RLN module it asks.
##
## A method call arrives on the host's thread as `logos_module_dispatch`,
## becomes a CBOR request to the library's own export, and this thread polls
## the node's context until the reply (nim-ffi's `poll_host`). Events reach
## the host's emit callback straight from the node's thread. The RLN
## questions the node asks (nim-ffi reverse calls) come here the same way and
## go to `liblogos_rln_module` through logos-core's lp_* C ABI; the answer goes
## back from wherever it arrives. The process holds three threads: the
## host's, logos-protocol's, and the node's.
##
## Build: nim c --app:staticlib --noMain --nimMainPrefix:liblogosdelivery
##   -d:ffiPollMode library/logos_module/module.nim

import std/[base64, json, times]
import results
import logos_sdk
import ../liblogosdelivery
from ../declare_lib import initializeLibrary # declareLibrary's once-only runtime init
import cbor_serialization # the request encoders instantiate here
import ffi/[cbor_serial, ffi_events, ffi_msg, ffi_reverse, poll_host]
import ./presets
import ../../logos_delivery/waku/rln/rln_lez/wire

const
  ModuleName = "delivery_module"
  ModuleVersion = "0.3.0"
  Contract = staticRead("delivery_module.lidl")
  RlnModule = "liblogos_rln_module"
  RlnLocalTimeoutMs = 10_000
  RlnRegistryReadTimeoutMs = 70_000

var
  rlnPreset: RlnPreset
  rlnStatus = "Disabled"

let host = newHost(importLibrary("logosdelivery", ctor = "logosdelivery_create_node"))

# --- events: the library's payloads onto the contract's events ------------------
# The library names its events in snake case and keys their payloads by
# field; the contract's events are positional. For each: the contract's
# name, then the payload fields in the contract's order. Every contract event
# ends with a timestamp, taken here.
const LibraryEvents = [
  ("message_queued", "messageQueued", @["requestId", "messageHash"]),
  ("message_sent", "messageSent", @["requestId", "messageHash"]),
  ("message_error", "messageError", @["requestId", "messageHash", "error"]),
  ("message_propagated", "messagePropagated", @["requestId", "messageHash"]),
  ("connection_status_change", "connectionStateChanged", @["connectionStatus"]),
  ("channel_message_received", "channelMessageReceived", @["channelId", "senderId", "payload"]),
  ("channel_message_sent", "channelMessageSent", @["channelId", "requestId"]),
  ("channel_message_error", "channelMessageError", @["channelId", "requestId", "error"]),
  ("node_started", "nodeStarted", @["success", "message"]),
  ("node_stopped", "nodeStopped", @["success", "message"]),
]

proc nowNs(): int64 =
  return int64(epochTime() * 1e9)

proc arg(j: JsonNode, field: string): JsonNode =
  ## A payload field as the contract carries it: a payload is base64 in the
  ## library's JSON and tagged bytes on the lp wire.
  let v = j{field}
  if v.isNil:
    return newJNull()
  if field != "payload":
    return v
  let bytes =
    try:
      cast[seq[byte]](base64.decode(v.getStr("")))
    except CatchableError:
      newSeq[byte]()
  return toLogosBytes(bytes)

proc onLibraryEvent(name: string, payload: pointer, len: int) {.nimcall, gcsafe, raises: [].} =
  ## nim-ffi hands each event here as it is emitted, on the node's thread,
  ## and the host's callback takes it from any thread.
  {.cast(gcsafe), cast(raises: []).}:
    var text = newString(len)
    if len > 0:
      copyMem(addr text[0], payload, len)
    let j =
      try:
        parseJson(text)
      except CatchableError:
        return
    let kind = j{"eventType"}.getStr("")
    if kind == "message_received":
      # the message rides nested, with a timestamp of its own
      let m = j{"message"}
      emitEvent("messageReceived", %[
        j.arg("messageHash"), m.arg("contentTopic"), m.arg("payload"), j.arg("source"),
        %int64(m{"timestamp"}.getFloat(0)),
      ])
      return
    for (libraryName, contractName, fields) in LibraryEvents:
      if kind == libraryName:
        var args = newJArray()
        for f in fields:
          args.add(j.arg(f))
        args.add(%nowNs())
        emitEvent(contractName, args)
        return
    # the rest (topic health, ...) the contract does not surface

setFFIEventSink(onLibraryEvent)

# --- request shapes: the exports' parameter names -------------------------------
type
  CreateNodeReq = object
    configJson: string
    rlnPlugin: bool
  Empty = object
  MessageReq = object
    messageJson: string
  TopicReq = object
    contentTopicStr: string
  StoreQueryReq = object
    jsonQuery: string
    peerAddr: string
    timeoutMs: int32
  ChannelCreateReq = object
    channelIdStr: string
    contentTopicStr: string
    senderIdStr: string
    encryptFn: uint64
    decryptFn: uint64
    userData: uint64
  ChannelReq = object
    channelIdStr: string
  ChannelSendReq = object
    channelIdStr: string
    messageJson: string
  NodeInfoReq = object
    nodeInfoId: string

# --- the node's RLN questions ---------------------------------------------------
# nim-ffi hands each question over on the node's thread; the module asks the
# RLN module with the preset's registry and identifier in front, and the
# answer goes straight back from lp's completion thread.
const
  AskMembershipState = nameId("rln_get_membership_state")
  AskEpochQuota = nameId("rln_get_epoch_quota")
  AskGenerateProof = nameId("rln_generate_proof")
  AskValidateProof = nameId("rln_validate_proof")

proc onRlnAnswer(ok: cint, json: cstring, userData: pointer) {.cdecl.} =
  when declared(setupForeignThreadGc):
    setupForeignThreadGc() # lp's thread is not ours
  let callId = cast[uint64](userData)
  {.cast(gcsafe).}:
    if ok != 0:
      discard host.reverseReply(callId, RET_OK, cborEncode($json))
    else:
      discard host.reverseReply(callId, RET_ERR, $json)

proc onRlnQuestion(callId, nameId: uint64, args: pointer, len: int) {.nimcall, gcsafe, raises: [].} =
  {.cast(gcsafe), cast(raises: []).}:
    template arguments(T: typedesc): untyped =
      cborDecode(cast[ptr UncheckedArray[byte]](args).toOpenArray(0, len - 1), T).valueOr:
        discard host.reverseReply(callId, RET_ERR, "bad arguments: " & error)
        return
    let scope = @[rlnPreset.registryId, rlnPreset.rlnIdentifier]
    var meth: string
    var params: seq[string]
    var timeoutMs = RlnLocalTimeoutMs
    case nameId
    of AskMembershipState:
      meth = "get_membership_state"
      params = scope
      timeoutMs = RlnRegistryReadTimeoutMs
    of AskEpochQuota:
      let q = arguments(RlnGetEpochQuotaHostCall)
      meth = "get_epoch_quota"
      params = scope & $q.timestamp
    of AskGenerateProof:
      let q = arguments(RlnGenerateProofHostCall)
      meth = "generate_proof"
      params = scope & @[q.signalHex, $q.timestamp]
      timeoutMs = RlnRegistryReadTimeoutMs
    of AskValidateProof:
      let q = arguments(RlnValidateProofHostCall)
      meth = "validate_proof"
      params = scope & @[q.signalHex, $q.timestamp, q.proofJson]
    else:
      discard host.reverseReply(callId, RET_ERR, "unknown question")
      return
    callModuleAsync(RlnModule, ModuleName, meth, %params, timeoutMs, onRlnAnswer, cast[pointer](callId)).isOkOr:
      discard host.reverseReply(callId, RET_ERR, error)

setFFIReverseSink(onRlnQuestion)

# --- the contract ---------------------------------------------------------------
proc toLogos[T](r: Result[T, string]): LogosResult =
  ## nim-ffi's answer as the contract's result.
  if r.isErr:
    return logosFail(r.error)
  when T is void:
    return logosOk()
  else:
    return logosOk(%r.value)

template requireNode(): untyped =
  if host.ctx.isNil:
    return logosFail("Context not initialized")

proc createNode(cfg: string): LogosResult {.dispatchAs: "createNode".} =
  if not host.ctx.isNil:
    return logosFail("Context already initialized")
  let presetName =
    try:
      parseJson(cfg){"preset"}.getStr("")
    except CatchableError:
      ""
  let preset = resolveRlnPreset(presetName).valueOr:
    return logosFail(error)
  if preset.enabled:
    # made here, on the host's thread: the questions come from the node's
    openClient(RlnModule, ModuleName).isOkOr:
      return logosFail("RLN module unreachable: " & error)
  rlnPreset = preset
  host.create(request({
    "configJson": cfg, "persistencePath": persistencePath,
    "rlnPlugin": preset.enabled, "rlnValidation": preset.enableValidation,
  })).isOkOr:
    return logosFail("Failed to create Delivery context: " & error)
  if preset.enabled:
    rlnStatus = "Ready"
    emitEvent("rlnStateChanged", %[%rlnStatus, %"", %nowNs()])
  return logosOk()

proc start(): LogosResult {.dispatchAs: "start".} =
  ## Returns once the start is under way; the outcome is the nodeStarted
  ## event, which the node emits itself (start can take a while).
  requireNode()
  discard host.submit("logosdelivery_start_node", request({})).valueOr:
    return logosFail("failed to initiate start: " & error)
  return logosOk()

proc stop(): LogosResult {.dispatchAs: "stop".} =
  requireNode()
  discard host.submit("logosdelivery_stop_node", request({})).valueOr:
    return logosFail("failed to initiate stop: " & error)
  return logosOk()

proc send(contentTopic: string, payload: seq[byte]): LogosResult {.dispatchAs: "send".} =
  requireNode()
  let msg = %*{"contentTopic": contentTopic, "payload": base64.encode(payload), "ephemeral": false}
  return host.call("logosdelivery_send", request({"messageJson": $msg})).decode(string).toLogos

proc subscribe(contentTopic: string): LogosResult {.dispatchAs: "subscribe".} =
  requireNode()
  return host.call("logosdelivery_subscribe", request({"contentTopicStr": contentTopic})).outcome.toLogos

proc unsubscribe(contentTopic: string): LogosResult {.dispatchAs: "unsubscribe".} =
  requireNode()
  return host.call("logosdelivery_unsubscribe", request({"contentTopicStr": contentTopic})).outcome.toLogos

proc storeQuery(jsonQuery: string, peerAddr: string, timeoutMs: int64): LogosResult {.dispatchAs: "storeQuery".} =
  requireNode()
  return host.call(
    "waku_store_query",
    request({"jsonQuery": jsonQuery, "peerAddr": peerAddr, "timeoutMs": int32(timeoutMs)}),
    max(host.timeoutMs, int(timeoutMs) + 5_000),
  ).decode(string).toLogos

proc channelCreate(channelId: string, contentTopic: string, senderId: string): LogosResult {.dispatchAs: "channelCreate".} =
  requireNode()
  # zero cipher callbacks and user data: an unencrypted channel
  return host.call("logosdelivery_channel_create", request({
    "channelIdStr": channelId, "contentTopicStr": contentTopic, "senderIdStr": senderId,
    "encryptFn": 0'u64, "decryptFn": 0'u64, "userData": 0'u64,
  })).decode(string).toLogos

proc channelExists(channelId: string): LogosResult {.dispatchAs: "channelExists".} =
  requireNode()
  return host.call("logosdelivery_channel_exists", request({"channelIdStr": channelId})).decode(bool).toLogos

proc channelSend(channelId: string, payload: seq[byte]): LogosResult {.dispatchAs: "channelSend".} =
  requireNode()
  let msg = %*{"payload": base64.encode(payload), "ephemeral": false}
  return host.call("logosdelivery_channel_send", request({"channelIdStr": channelId, "messageJson": $msg})).decode(string).toLogos

proc channelClose(channelId: string): LogosResult {.dispatchAs: "channelClose".} =
  requireNode()
  return host.call("logosdelivery_channel_close", request({"channelIdStr": channelId})).outcome.toLogos

proc getAvailableNodeInfoIDs(): LogosResult {.dispatchAs: "getAvailableNodeInfoIDs".} =
  requireNode()
  return host.call("logosdelivery_get_available_node_info_ids", request({})).decode(string).toLogos

proc getNodeInfo(nodeInfoId: string): LogosResult {.dispatchAs: "getNodeInfo".} =
  requireNode()
  return host.call("logosdelivery_get_node_info", request({"nodeInfoId": nodeInfoId})).decode(string).toLogos

proc getAvailableConfigs(): LogosResult {.dispatchAs: "getAvailableConfigs".} =
  requireNode()
  return host.call("logosdelivery_get_available_configs", request({})).decode(string).toLogos

proc collectOpenMetricsText(): string {.dispatchAs: "collectOpenMetricsText".} =
  if host.ctx.isNil:
    return ""
  return host.call("logosdelivery_get_node_info", request({"nodeInfoId": "Metrics"})).decode(string).valueOr("")

proc rlnBridgeEnable(): LogosResult {.dispatchAs: "rlnBridgeEnable".} =
  ## Kept for the contract: the node asks the RLN module itself, through
  ## logos-core, so there is no bridge to bring up.
  return logosOk()

proc rlnState(): LogosResult {.dispatchAs: "rlnState".} =
  var v = %*{"state": rlnStatus, "message": ""}
  if rlnPreset.enabled:
    v["registryId"] = %rlnPreset.registryId
    v["rlnIdentifier"] = %rlnPreset.rlnIdentifier
    v["epochSizeSec"] = %rlnPreset.epochSizeSec
  return logosOk(v)

logosModule(ModuleName, ModuleVersion, Contract, initializeLibrary)
