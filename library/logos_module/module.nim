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
## Build: nim c --app:staticlib --noMain --nimMainPrefix:liblogosdelivery
##   -d:ffiPollMode -d:logosModule library/logos_module/module.nim

import std/[base64, json, sequtils]
import results
import logos_sdk
import ../liblogosdelivery
from ../declare_lib import initializeLibrary # declareLibrary's once-only runtime init
import cbor_serialization # the request encoders instantiate here
import ffi/ffi_events
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

let host = newHost(importLibrary("logosdelivery", ctor = "logosdelivery_create_node"))

# The library's events come here as they are emitted, on the node's thread,
# instead of waiting in the queue for the next call to pump them.
proc onLibraryEvent(name: string, payload: pointer, len: int) {.nimcall, gcsafe, raises: [].} =
  var text = newString(len)
  if len > 0:
    copyMem(addr text[0], payload, len)
  emitLibraryEvent(text)

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

# --- calls and their outcomes -------------------------------------------------
template ask(name: static string, req: untyped, timeoutMs = CallTimeoutMs): Reply =
  host.call(name, encode(req), timeoutMs)

proc failure(r: Reply): string =
  return if r.error.len > 0: r.error else: "rc=" & $r.ret

proc asText(r: Reply): LogosResult =
  if r.ret != RET_OK:
    return logosFail(r.failure)
  return logosOk(%r.decode(string).valueOr(""))

proc asBool(r: Reply): LogosResult =
  if r.ret != RET_OK:
    return logosFail(r.failure)
  return logosOk(%r.decode(bool).valueOr(false))

proc asVoid(r: Reply): LogosResult =
  return if r.ret != RET_OK: logosFail(r.failure) else: logosOk()

template requireNode(): untyped =
  if host.ctx.isNil:
    return logosFail("Context not initialized")

# --- the config the node gets ----------------------------------------------------
const Layered = ["entryLayer", "mode", "preset", "kernelConf", "messagingOverrides", "channelsOverrides"]

proc withDefaults(cfg: JsonNode, persistence: string, disableRlnValidation: bool): JsonNode =
  ## The persistence path the host gave us, and validation off when the preset
  ## says so, into the layer of the config that owns them: kernelConf when
  ## present, messagingOverrides on a layered config, the config itself when
  ## it is a flat WakuNodeConf. A kernel-only node keeps its config as is.
  var target = cfg
  if cfg.hasKey("kernelConf"):
    target = cfg["kernelConf"]
  elif cfg{"entryLayer"}.getStr("") == "kernel":
    return cfg
  elif cfg.keys.toSeq.allIt(it in Layered):
    if not cfg.hasKey("messagingOverrides"):
      cfg["messagingOverrides"] = newJObject()
    target = cfg["messagingOverrides"]
  if target.kind != JObject:
    return cfg
  if persistence.len > 0 and not target.hasKey("localStoragePath") and not target.hasKey("local-storage-path"):
    target["localStoragePath"] = %(persistence & "/data")
  if disableRlnValidation:
    target["rln-disable-validation"] = %true
  return cfg

# --- the contract ---------------------------------------------------------------
proc createNode(cfgJson: string): LogosResult {.dispatchAs: "createNode".} =
  if not host.ctx.isNil:
    return logosFail("Context already initialized")
  let cfg =
    try:
      parseJson(cfgJson)
    except CatchableError:
      return logosFail("Invalid JSON config")
  if cfg.kind != JObject:
    return logosFail("Invalid JSON config")
  let preset = resolveRlnPreset(cfg{"preset"}.getStr("")).valueOr:
    return logosFail(error)
  rlnPreset = preset
  if preset.enabled:
    setRlnScope(preset.registryId, preset.rlnIdentifier).isOkOr:
      return logosFail("RLN module unreachable: " & error)
    rlnStateName = "Initializing"
    rlnStateMessage = ""
  let config = $withDefaults(cfg, persistencePath, preset.enabled and not preset.enableValidation)
  host.create(encode(CreateNodeReq(configJson: config, rlnPlugin: preset.enabled)), CallTimeoutMs).isOkOr:
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
  discard host.submit("logosdelivery_start_node", encode(Empty())).valueOr:
    return logosFail("failed to initiate start: " & error)
  return logosOk()

proc stop(): LogosResult {.dispatchAs: "stop".} =
  requireNode()
  discard host.submit("logosdelivery_stop_node", encode(Empty())).valueOr:
    return logosFail("failed to initiate stop: " & error)
  return logosOk()

proc send(contentTopic: string, payload: seq[byte]): LogosResult {.dispatchAs: "send".} =
  requireNode()
  let msg = %*{"contentTopic": contentTopic, "payload": base64.encode(payload), "ephemeral": false}
  return ask("logosdelivery_send", MessageReq(messageJson: $msg)).asText

proc subscribe(contentTopic: string): LogosResult {.dispatchAs: "subscribe".} =
  requireNode()
  return ask("logosdelivery_subscribe", TopicReq(contentTopicStr: contentTopic)).asVoid

proc unsubscribe(contentTopic: string): LogosResult {.dispatchAs: "unsubscribe".} =
  requireNode()
  return ask("logosdelivery_unsubscribe", TopicReq(contentTopicStr: contentTopic)).asVoid

proc storeQuery(jsonQuery: string, peerAddr: string, timeoutMs: int64): LogosResult {.dispatchAs: "storeQuery".} =
  requireNode()
  let budget = max(CallTimeoutMs, int(timeoutMs) + 5_000)
  return ask("waku_store_query", StoreQueryReq(jsonQuery: jsonQuery, peerAddr: peerAddr, timeoutMs: int32(timeoutMs)), budget).asText

proc channelCreate(channelId: string, contentTopic: string, senderId: string): LogosResult {.dispatchAs: "channelCreate".} =
  requireNode()
  # zero cipher callbacks and user data: an unencrypted channel
  return ask("logosdelivery_channel_create", ChannelCreateReq(channelIdStr: channelId, contentTopicStr: contentTopic, senderIdStr: senderId)).asText

proc channelExists(channelId: string): LogosResult {.dispatchAs: "channelExists".} =
  requireNode()
  return ask("logosdelivery_channel_exists", ChannelReq(channelIdStr: channelId)).asBool

proc channelSend(channelId: string, payload: seq[byte]): LogosResult {.dispatchAs: "channelSend".} =
  requireNode()
  let msg = %*{"payload": base64.encode(payload), "ephemeral": false}
  return ask("logosdelivery_channel_send", ChannelSendReq(channelIdStr: channelId, messageJson: $msg)).asText

proc channelClose(channelId: string): LogosResult {.dispatchAs: "channelClose".} =
  requireNode()
  return ask("logosdelivery_channel_close", ChannelReq(channelIdStr: channelId)).asVoid

proc getAvailableNodeInfoIDs(): LogosResult {.dispatchAs: "getAvailableNodeInfoIDs".} =
  requireNode()
  return ask("logosdelivery_get_available_node_info_ids", Empty()).asText

proc getNodeInfo(nodeInfoId: string): LogosResult {.dispatchAs: "getNodeInfo".} =
  requireNode()
  return ask("logosdelivery_get_node_info", NodeInfoReq(nodeInfoId: nodeInfoId)).asText

proc getAvailableConfigs(): LogosResult {.dispatchAs: "getAvailableConfigs".} =
  requireNode()
  return ask("logosdelivery_get_available_configs", Empty()).asText

proc collectOpenMetricsText(): string {.dispatchAs: "collectOpenMetricsText".} =
  if host.ctx.isNil:
    return ""
  return ask("logosdelivery_get_node_info", NodeInfoReq(nodeInfoId: "Metrics")).decode(string).valueOr("")

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
