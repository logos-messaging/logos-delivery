## C-ABI FFI library for the browser edge node. Exposes, over the (patched,
## single-threaded) ffi:
##   edge_new(serviceNode, cb, ud) -> ctx        (build node, mount, connect)
##   edge_lightpush_publish(ctx, cb, ud, topic, jsonMsg)
##   edge_filter_subscribe(ctx, cb, ud, topic, contentTopics)
##   logosdeliveryedge_set_event_callback(ctx, cb, ud)   (filter push events)
##   ffi_poll()                                  (host-driven chronos pump)
##
## Async handlers (connect / lightpush / filter) await the network; the browser
## host drives `ffi_poll()` from its event loop and the per-request callback
## fires on completion (see the cooperative transport in wasm-deps/ffi).

import std/[json, options, strutils, locks, base64]
import chronos, chronicles, results
import stew/byteutils
import ffi
import ./wasm_shims
import libp2p/crypto/crypto
import libp2p/switch  # for Switch.stop in edge_stop — without it `stop` binds to chronos'
import
  ./edge_node,
  ./edge_ops,
  logos_delivery/waku/waku_core/message/message,
  logos_delivery/waku/waku_core/message/digest,
  logos_delivery/waku/waku_core/time,
  logos_delivery/waku/waku_core/topics/pubsub_topic,
  logos_delivery/waku/waku_core/subscription/push_handler,
  logos_delivery/waku/waku_store/common,
  logos_delivery/waku/common/paging

declareLibrary("logosdeliveryedge")

# --- event callback wiring (filter push messages) ----------------------------
var eventCallbackLock: Lock
initLock(eventCallbackLock)

proc logosdeliveryedge_set_event_callback(
    ctx: ptr FFIContext[EdgeNode], callback: FFICallBack, userData: pointer
) {.exportc, cdecl.} =
  if isNil(ctx):
    echo "error: invalid context in logosdeliveryedge_set_event_callback"
    return
  eventCallbackLock.acquire()
  defer:
    eventCallbackLock.release()
  ctx[].eventCallback = cast[pointer](callback)
  ctx[].eventUserData = userData

# --- create node -------------------------------------------------------------
registerReqFFI(CreateEdgeNodeRequest, ctx: ptr FFIContext[EdgeNode]):
  proc(serviceNode: cstring): Future[Result[string, string]] {.async.} =
    echo "[edge] creating edge node…"
    let rng = crypto.newRng()
    let privKey = crypto.PrivateKey.random(PKScheme.Secp256k1, rng[]).valueOr:
      return err("keygen failed: " & $error)
    let node =
      try:
        newEdgeNode(rng, privKey)
      except CatchableError as e:
        return err("newEdgeNode failed: " & e.msg)
    echo "[edge] libp2p switch built (browser-WebSocket transport)"
    node.mountLightPushClient()
    node.mountStoreClient()
    await node.startMetadata()
    await node.mountFilterClient()
    echo "[edge] lightpush + filter + store clients mounted; dialing ", $serviceNode
    (await node.connectToServiceNode(@[$serviceNode])).isOkOr:
      echo "[edge] connect FAILED: ", $error
      return err("connect failed: " & $error)
    ctx.myLib[] = node
    echo "[edge] connected — edge node ready"
    return ok("")

proc edge_new(
    serviceNode: cstring, callback: FFICallBack, userData: pointer
): pointer {.exportc, cdecl.} =
  initializeLibrary()
  if isNil(callback):
    echo "error: missing callback in edge_new"
    return nil
  var ctx = ffi.createFFIContext[EdgeNode]().valueOr:
    let msg = "Error in createFFIContext: " & $error
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
    return nil
  ctx.userData = userData
  ffi.sendRequestToFFIThread(
    ctx, CreateEdgeNodeRequest.ffiNewReq(callback, userData, serviceNode)
  ).isOkOr:
    let msg = "error in sendRequestToFFIThread: " & $error
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
    return nil
  return cast[pointer](ctx)

# --- lightpush ---------------------------------------------------------------
proc edge_lightpush_publish(
    ctx: ptr FFIContext[EdgeNode],
    callback: FFICallBack,
    userData: pointer,
    pubsubTopic: cstring,
    contentTopic: cstring,
    payload: cstring,
    metaB64: cstring,
) {.ffi.} =
  ## Build a WakuMessage from a content topic + UTF-8 payload and lightpush it. `metaB64` is
  ## an optional base64 app-defined `meta` field (<=64 bytes) — e.g. a message signature.
  let metaBytes =
    try: toBytes(base64.decode($metaB64))
    except CatchableError: newSeq[byte](0)
  let msg = WakuMessage(
    payload: toBytes($payload),
    contentTopic: $contentTopic,
    meta: metaBytes,
    version: 0'u32,
    timestamp: getNowInNanosecondTime(),
  )
  echo "[edge] lightpush → ", $contentTopic, " (", msg.payload.len, " bytes) on ",
    $pubsubTopic
  let msgHash = (await ctx.myLib[].lightpushPublish($pubsubTopic, msg)).valueOr:
    echo "[edge] lightpush FAILED: ", $error
    return err($error)
  echo "[edge] lightpush OK (", msgHash, ")"
  return ok(msgHash)

# --- filter ------------------------------------------------------------------
proc edge_filter_subscribe(
    ctx: ptr FFIContext[EdgeNode],
    callback: FFICallBack,
    userData: pointer,
    pubsubTopic: cstring,
    contentTopics: cstring,
) {.ffi.} =
  proc onPush(pubsubTopic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
    echo "[edge] filter push received on ", msg.contentTopic, " (",
      msg.payload.len, " bytes)"
    callEventCallback(ctx, "onReceivedMessage"):
      $(
        %*{
          "pubsubTopic": string(pubsubTopic),
          "contentTopic": msg.contentTopic,
          "payload": string.fromBytes(msg.payload),
          "meta": base64.encode(msg.meta),
        }
      )

  echo "[edge] filter subscribe → ", $contentTopics, " on ", $pubsubTopic
  (
    await ctx.myLib[].filterSubscribe(
      $pubsubTopic, ($contentTopics).split(","), FilterPushHandler(onPush)
    )
  ).isOkOr:
    echo "[edge] filter subscribe FAILED: ", $error
    return err($error)
  echo "[edge] filter subscribe OK"
  return ok("")

# --- store (history) ---------------------------------------------------------
# Every numeric argument crosses as a DECIMAL STRING, not a number. Waku
# timestamps are nanoseconds (~1.75e18), well past JS's Number.MAX_SAFE_INTEGER
# (9.007e15), so passing them as `ccall('number')` — or letting JSON.parse see
# them as numbers on the way back — silently corrupts the low digits and breaks
# cursor-based paging.
proc edge_store_connect(
    ctx: ptr FFIContext[EdgeNode],
    callback: FFICallBack,
    userData: pointer,
    storeNode: cstring,
) {.ffi.} =
  ## Dial a dedicated store peer. Only needed when the service node doesn't serve
  ## store itself (a bootstrap node typically doesn't).
  echo "[edge] dialing store node ", $storeNode
  (await ctx.myLib[].connectToStoreNode(@[$storeNode])).isOkOr:
    echo "[edge] store connect FAILED: ", $error
    return err($error)
  echo "[edge] store node connected"
  return ok("")

proc edge_store_query(
    ctx: ptr FFIContext[EdgeNode],
    callback: FFICallBack,
    userData: pointer,
    pubsubTopic: cstring,
    contentTopics: cstring,
    startNs: cstring,
    endNs: cstring,
    pageSize: cstring,
    forward: cstring,
    cursorHex: cstring,
) {.ffi.} =
  ## One page of history. `startNs`/`endNs`/`cursorHex` are optional ("" = unset);
  ## `forward` is "true"/"false". Returns
  ##   {"messages":[{hash,contentTopic,payload,meta,timestamp}], "cursor":"…"}
  ## with `timestamp` as a decimal string and `cursor` "" when the page is last.
  # NOTE: `some` must be qualified — `results` is imported here too and its Opt.some
  # would otherwise win over std/options for these Option[T] fields.
  var limit =
    try: uint64(parseBiggestUInt($pageSize))
    except ValueError: DefaultPageSize
  if limit == 0'u64: limit = DefaultPageSize
  if limit > MaxPageSize: limit = MaxPageSize

  var storeReq = StoreQueryRequest(
    includeData: true,
    pubsubTopic: options.some(PubsubTopic($pubsubTopic)),
    contentTopics: ($contentTopics).split(","),
    paginationForward: ($forward).into(),
    paginationLimit: options.some(limit),
  )
  if ($startNs).len > 0:
    storeReq.startTime =
      try: options.some(Timestamp(parseBiggestInt($startNs)))
      except ValueError: return err("bad startNs: " & $startNs)
  if ($endNs).len > 0:
    storeReq.endTime =
      try: options.some(Timestamp(parseBiggestInt($endNs)))
      except ValueError: return err("bad endNs: " & $endNs)
  if ($cursorHex).len > 0:
    let cursor = hexToHash($cursorHex).valueOr:
      return err("bad cursor: " & error)
    storeReq.paginationCursor = options.some(cursor)

  echo "[edge] store query → ", $contentTopics, " (limit ", limit, ") on ", $pubsubTopic
  let resp = (await ctx.myLib[].storeQuery(storeReq)).valueOr:
    echo "[edge] store query FAILED: ", $error
    return err($error)

  var arr = newJArray()
  for kv in resp.messages:
    if kv.message.isNone():
      continue
    let m = kv.message.get()
    arr.add(
      %*{
        "hash": kv.messageHash.to0xHex(),
        "contentTopic": m.contentTopic,
        "payload": string.fromBytes(m.payload),
        "meta": base64.encode(m.meta),
        "timestamp": $m.timestamp,
      }
    )
  echo "[edge] store query OK (", arr.len, " messages)"
  return ok(
    $(
      %*{
        "messages": arr,
        "cursor":
          if resp.paginationCursor.isSome(): resp.paginationCursor.get().to0xHex()
          else: "",
      }
    )
  )

# --- teardown ----------------------------------------------------------------
proc edge_stop(
    ctx: ptr FFIContext[EdgeNode], callback: FFICallBack, userData: pointer
) {.ffi.} =
  ## Stop the libp2p switch. Without this, "disconnect" in an app leaves the
  ## WebSocket to the service node open and the server still pushing filter
  ## messages into a dead callback, and a later reconnect builds a SECOND node.
  echo "[edge] stopping switch…"
  try:
    await ctx.myLib[].switch.stop()
  except CatchableError as e:
    return err("switch stop failed: " & e.msg)
  echo "[edge] switch stopped"
  return ok("")

# Build as a wasm MAIN module (not a -shared SIDE module): drop --nimMainPrefix
# (which made Nim treat this as a dynamic lib) and alias the NimMain symbol that
# declareLibrary's initializeLibrary importc's. Nim emits a `main` (the module
# has top-level init), so the runtime initializes on load; initializeLibrary's
# guarded re-call is then a no-op.
when defined(emscripten):
  # Provide the C symbol declareLibrary's initializeLibrary importc's, aliased to
  # the runtime's NimMain (emitted because we build WITHOUT --nimMainPrefix).
  {.emit: """
void NimMain(void);
void liblogosdeliveryedgeNimMain(void) { NimMain(); }
""".}
