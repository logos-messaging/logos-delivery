## logos-delivery as a Logos Core module, in one image: liblogosdelivery's
## nim-ffi exports plus the `logos_module_*` exports logos-core's plugin glue
## calls. Three parts and nothing between them: logos-core (which carries
## every call between modules), this, and the RLN module it asks.
##
## A method call arrives on the host's thread as `logos_module_dispatch`,
## becomes a CBOR request to the library's own export, and this thread polls
## the node's context until the reply (nim-ffi's `poll_host`). Events reach
## the host's emit callback straight from the node's thread (events.nim). The
## RLN questions the node asks go to `liblogos_rln_module` through logos-core's
## lp_* C ABI, from the node's thread (rln_lez/wire.nim). The process holds
## three threads: the host's, logos-protocol's, and the node's.
##
## Imported by library/liblogosdelivery.nim under -d:logosModule; see the
## liblogosdeliveryModule nimble task.

import std/[base64, json, strutils]
import results
import logos_sdk
from ../declare_lib import initializeLibrary # declareLibrary's once-only runtime init
import cbor_serialization # the request encoders instantiate here
import ffi/ffi_msg
import ffi/poll_host
import ./events, ./presets
import ../../logos_delivery/waku/rln/rln_lez/wire

const
  ModuleName = "delivery_module"
  ModuleVersion = "0.3.0"
  Contract = staticRead("delivery_module.lidl")
  CallTimeoutMs = 30_000

var
  rlnPreset: RlnPreset
  rlnStateName = "Disabled"
  rlnStateMessage = ""

# --- the library's exports, by C name --------------------------------------------
proc ldCreateNode(req: ptr byte, len: csize_t, ctxOut: ptr pointer, idOut: ptr uint64): cint {.importc: "logosdelivery_create_node", cdecl, gcsafe, raises: [].}
proc ldDestroy(ctx: pointer): cint {.importc: "logosdelivery_destroy", cdecl, gcsafe, raises: [].}
proc ldPoll(ctx: pointer, timeoutMs: int32, msg: ptr ptr NimFfiMsg): cint {.importc: "logosdelivery_poll", cdecl, gcsafe, raises: [].}
proc ldStartNode(ctx: pointer, req: ptr byte, len: csize_t, idOut: ptr uint64): cint {.importc: "logosdelivery_start_node", cdecl, gcsafe, raises: [].}
proc ldStopNode(ctx: pointer, req: ptr byte, len: csize_t, idOut: ptr uint64): cint {.importc: "logosdelivery_stop_node", cdecl, gcsafe, raises: [].}
proc ldSend(ctx: pointer, req: ptr byte, len: csize_t, idOut: ptr uint64): cint {.importc: "logosdelivery_send", cdecl, gcsafe, raises: [].}
proc ldSubscribe(ctx: pointer, req: ptr byte, len: csize_t, idOut: ptr uint64): cint {.importc: "logosdelivery_subscribe", cdecl, gcsafe, raises: [].}
proc ldUnsubscribe(ctx: pointer, req: ptr byte, len: csize_t, idOut: ptr uint64): cint {.importc: "logosdelivery_unsubscribe", cdecl, gcsafe, raises: [].}
proc ldStoreQuery(ctx: pointer, req: ptr byte, len: csize_t, idOut: ptr uint64): cint {.importc: "waku_store_query", cdecl, gcsafe, raises: [].}
proc ldChannelCreate(ctx: pointer, req: ptr byte, len: csize_t, idOut: ptr uint64): cint {.importc: "logosdelivery_channel_create", cdecl, gcsafe, raises: [].}
proc ldChannelExists(ctx: pointer, req: ptr byte, len: csize_t, idOut: ptr uint64): cint {.importc: "logosdelivery_channel_exists", cdecl, gcsafe, raises: [].}
proc ldChannelSend(ctx: pointer, req: ptr byte, len: csize_t, idOut: ptr uint64): cint {.importc: "logosdelivery_channel_send", cdecl, gcsafe, raises: [].}
proc ldChannelClose(ctx: pointer, req: ptr byte, len: csize_t, idOut: ptr uint64): cint {.importc: "logosdelivery_channel_close", cdecl, gcsafe, raises: [].}
proc ldGetAvailableNodeInfoIds(ctx: pointer, req: ptr byte, len: csize_t, idOut: ptr uint64): cint {.importc: "logosdelivery_get_available_node_info_ids", cdecl, gcsafe, raises: [].}
proc ldGetNodeInfo(ctx: pointer, req: ptr byte, len: csize_t, idOut: ptr uint64): cint {.importc: "logosdelivery_get_node_info", cdecl, gcsafe, raises: [].}
proc ldGetAvailableConfigs(ctx: pointer, req: ptr byte, len: csize_t, idOut: ptr uint64): cint {.importc: "logosdelivery_get_available_configs", cdecl, gcsafe, raises: [].}

# Events bypass the queue in this image (declare_lib's emitEvent), so the host
# sees replies only; one that did arrive here would still reach the callback.
proc onLibraryEvent(nameId: uint64, payload: seq[byte]) {.gcsafe, raises: [].} =
  var text = newString(payload.len)
  if payload.len > 0:
    copyMem(addr text[0], unsafeAddr payload[0], payload.len)
  emitLibraryEvent(text)

let host = newHost(
  Library(create: ldCreateNode, destroy: ldDestroy, poll: ldPoll), onEvent = onLibraryEvent
)

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

# --- results ----------------------------------------------------------------
proc failed(what: string, r: Reply): LogosResult =
  return logosFail(what & ": " & (if r.error.len > 0: r.error else: "rc=" & $r.ret))

proc textResult(what: string, r: Reply): LogosResult =
  if r.ret != RET_OK:
    return failed(what, r)
  return logosOk(%r.decode(string).valueOr(""))

proc voidResult(what: string, r: Reply): LogosResult =
  if r.ret != RET_OK:
    return failed(what, r)
  return logosOk()

template requireNode(): untyped =
  if host.ctx.isNil:
    return logosFail("Context not initialized")

# --- config defaults, as the C++ module applied them -----------------------
proc findKey(obj: JsonNode, names: openArray[string]): string =
  for k, _ in obj.pairs:
    if k.toLowerAscii() in names:
      return k
  return ""

proc isFlatShape(obj: JsonNode): bool =
  for k, _ in obj.pairs:
    if k.toLowerAscii() notin ["entrylayer", "mode", "preset", "kernelconf", "messagingoverrides", "channelsoverrides"]:
      return true
  return false

proc applyConfigDefaults(cfg: string, persistence: string, disableRlnValidation: bool): Result[string, string] =
  var obj: JsonNode
  try:
    obj = parseJson(cfg)
  except CatchableError:
    return err("Invalid JSON config")
  if obj.kind != JObject:
    return err("Invalid JSON config")
  if persistence.len > 0 or disableRlnValidation:
    var target: JsonNode = obj
    let entryKey = findKey(obj, ["entrylayer"])
    let kernelEntry = entryKey.len > 0 and obj[entryKey].kind == JString and obj[entryKey].getStr().toLowerAscii() == "kernel"
    let kernelConfKey = findKey(obj, ["kernelconf"])
    if kernelConfKey.len > 0 and obj[kernelConfKey].kind == JObject:
      target = obj[kernelConfKey]
    elif kernelEntry:
      target = nil
    elif not isFlatShape(obj):
      var overridesKey = findKey(obj, ["messagingoverrides"])
      if overridesKey.len == 0:
        obj["messagingOverrides"] = newJObject()
        overridesKey = "messagingOverrides"
      target = if obj[overridesKey].kind == JObject: obj[overridesKey] else: nil
    if target != nil and persistence.len > 0 and findKey(target, ["localstoragepath", "local-storage-path"]).len == 0:
      target["localStoragePath"] = %(persistence & "/data")
    if target != nil and disableRlnValidation:
      target["rln-disable-validation"] = %true
  return ok($obj)

# --- the contract ---------------------------------------------------------------
proc createNode(cfg: string): LogosResult {.dispatchAs: "createNode".} =
  if not host.ctx.isNil:
    return logosFail("Context already initialized")
  var presetName = ""
  try:
    let obj = parseJson(cfg)
    if obj.kind == JObject:
      let k = findKey(obj, ["preset"])
      if k.len > 0 and obj[k].kind == JString:
        presetName = obj[k].getStr()
  except CatchableError:
    discard
  let preset = resolveRlnPreset(presetName).valueOr:
    return logosFail(error)
  let cfgWithDefaults = applyConfigDefaults(cfg, persistencePath, preset.enabled and not preset.enableValidation).valueOr:
    return logosFail(error)
  rlnPreset = preset
  if preset.enabled:
    setRlnScope(preset.registryId, preset.rlnIdentifier).isOkOr:
      return logosFail("RLN module unreachable: " & error)
    rlnStateName = "Initializing"
    rlnStateMessage = ""
  host.create(encode(CreateNodeReq(configJson: cfgWithDefaults, rlnPlugin: preset.enabled)), CallTimeoutMs).isOkOr:
    if preset.enabled:
      rlnStateName = "Disabled"
    return logosFail("Failed to create Delivery context: " & error)
  if preset.enabled:
    # The node's own start asks the RLN module to start (rln_lez.startModule);
    # what this module reports is whether it could reach the RLN module at all.
    rlnStateName = "Ready"
    rlnStateChanged(rlnStateName, rlnStateMessage, nowNs())
  return logosOk()

proc start(): LogosResult {.dispatchAs: "start".} =
  ## Returns once the start is under way; the outcome is the nodeStarted
  ## event, which the node emits itself (start can take a while).
  requireNode()
  discard host.submit(ldStartNode, encode(Empty())).valueOr:
    return logosFail("failed to initiate start: " & error)
  return logosOk()

proc stop(): LogosResult {.dispatchAs: "stop".} =
  requireNode()
  discard host.submit(ldStopNode, encode(Empty())).valueOr:
    return logosFail("failed to initiate stop: " & error)
  return logosOk()

proc send(contentTopic: string, payload: seq[byte]): LogosResult {.dispatchAs: "send".} =
  requireNode()
  let msg = %*{"contentTopic": contentTopic, "payload": base64.encode(payload), "ephemeral": false}
  return textResult("send", host.call(ldSend, encode(MessageReq(messageJson: $msg)), CallTimeoutMs))

proc subscribe(contentTopic: string): LogosResult {.dispatchAs: "subscribe".} =
  requireNode()
  return voidResult("subscribe", host.call(ldSubscribe, encode(TopicReq(contentTopicStr: contentTopic)), CallTimeoutMs))

proc unsubscribe(contentTopic: string): LogosResult {.dispatchAs: "unsubscribe".} =
  requireNode()
  return voidResult("unsubscribe", host.call(ldUnsubscribe, encode(TopicReq(contentTopicStr: contentTopic)), CallTimeoutMs))

proc storeQuery(jsonQuery: string, peerAddr: string, timeoutMs: int64): LogosResult {.dispatchAs: "storeQuery".} =
  requireNode()
  let budget = max(CallTimeoutMs, int(timeoutMs) + 5_000)
  return textResult("store_query", host.call(ldStoreQuery, encode(StoreQueryReq(jsonQuery: jsonQuery, peerAddr: peerAddr, timeoutMs: int32(timeoutMs))), budget))

proc channelCreate(channelId: string, contentTopic: string, senderId: string): LogosResult {.dispatchAs: "channelCreate".} =
  requireNode()
  # zero cipher callbacks and user data: an unencrypted channel
  return textResult("channel_create", host.call(ldChannelCreate, encode(ChannelCreateReq(channelIdStr: channelId, contentTopicStr: contentTopic, senderIdStr: senderId)), CallTimeoutMs))

proc channelExists(channelId: string): LogosResult {.dispatchAs: "channelExists".} =
  requireNode()
  let r = host.call(ldChannelExists, encode(ChannelReq(channelIdStr: channelId)), CallTimeoutMs)
  if r.ret != RET_OK:
    return failed("channel_exists", r)
  return logosOk(%r.decode(bool).valueOr(false))

proc channelSend(channelId: string, payload: seq[byte]): LogosResult {.dispatchAs: "channelSend".} =
  requireNode()
  let msg = %*{"payload": base64.encode(payload), "ephemeral": false}
  return textResult("channel_send", host.call(ldChannelSend, encode(ChannelSendReq(channelIdStr: channelId, messageJson: $msg)), CallTimeoutMs))

proc channelClose(channelId: string): LogosResult {.dispatchAs: "channelClose".} =
  requireNode()
  return voidResult("channel_close", host.call(ldChannelClose, encode(ChannelReq(channelIdStr: channelId)), CallTimeoutMs))

proc getAvailableNodeInfoIDs(): LogosResult {.dispatchAs: "getAvailableNodeInfoIDs".} =
  requireNode()
  return textResult("get_available_node_info_ids", host.call(ldGetAvailableNodeInfoIds, encode(Empty()), CallTimeoutMs))

proc getNodeInfo(nodeInfoId: string): LogosResult {.dispatchAs: "getNodeInfo".} =
  requireNode()
  return textResult("get_node_info", host.call(ldGetNodeInfo, encode(NodeInfoReq(nodeInfoId: nodeInfoId)), CallTimeoutMs))

proc getAvailableConfigs(): LogosResult {.dispatchAs: "getAvailableConfigs".} =
  requireNode()
  return textResult("get_available_configs", host.call(ldGetAvailableConfigs, encode(Empty()), CallTimeoutMs))

proc collectOpenMetricsText(): string {.dispatchAs: "collectOpenMetricsText".} =
  if host.ctx.isNil:
    return ""
  let r = host.call(ldGetNodeInfo, encode(NodeInfoReq(nodeInfoId: "Metrics")), CallTimeoutMs)
  return r.decode(string).valueOr("")

proc rlnBridgeEnable(): LogosResult {.dispatchAs: "rlnBridgeEnable".} =
  ## Kept for the contract: the node asks the RLN module itself, through
  ## logos-core, so there is no bridge to bring up.
  return logosOk()

proc rlnState(): LogosResult {.dispatchAs: "rlnState".} =
  var v = %*{"state": rlnStateName, "message": rlnStateMessage}
  if rlnPreset.enabled:
    v["registryId"] = %rlnPreset.registryId
    v["rlnIdentifier"] = %rlnPreset.rlnIdentifier
    v["epochSizeSec"] = %rlnPreset.epochSizeSec
  return logosOk(v)

logosModule(ModuleName, ModuleVersion, Contract, initializeLibrary)
