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
import ffi # under -d:emscripten this resolves to wasm-deps/ffi, see config.nims
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

declareLibrary("logosdeliveryedge", EdgeNode, defaultABIFormat = "c")

# --- event callback wiring (filter push messages) ----------------------------
#
# nim-ffi 0.3.0 dropped `eventCallback` / `eventUserData` from FFIContext in
# favour of a listener registry reached through `<lib>_add_event_listener`. We
# keep the single-callback surface instead: it is the ABI ld-edge.js already
# speaks, and a browser edge node has exactly one context, so a module-level
# slot is equivalent to a per-context one.
var
  eventCallbackLock: Lock
  gEventCallback: FFICallBack
  gEventUserData: pointer
initLock(eventCallbackLock)

proc logosdeliveryedge_set_event_callback(
    ctx: ptr FFIContext[EdgeNode], callback: FFICallBack, userData: pointer
) {.exportc, cdecl.} =
  ## `ctx` is unused — kept in the signature so the exported C symbol is
  ## unchanged for existing callers.
  eventCallbackLock.acquire()
  defer:
    eventCallbackLock.release()
  gEventCallback = callback
  gEventUserData = userData

proc emitEdgeEvent(eventName: string, payload: string) =
  ## Hands `payload` to the registered callback verbatim, matching what
  ## nim-ffi 0.1.x's `callEventCallback` put on the wire: RET_OK plus the raw
  ## JSON bytes (NOT NUL-terminated), which is what ld-edge.js parses.
  eventCallbackLock.acquire()
  let
    cb = gEventCallback
    ud = gEventUserData
  eventCallbackLock.release()
  if cb.isNil:
    chronicles.error "no event callback registered", event = eventName
    return
  try:
    if payload.len == 0:
      cb(RET_OK, nil, 0.csize_t, ud)
    else:
      cb(RET_OK, unsafeAddr payload[0], payload.len.csize_t, ud)
  except Exception, CatchableError:
    chronicles.error "event callback raised",
      event = eventName, error = getCurrentExceptionMsg()

# --- create node -------------------------------------------------------------
registerReqFFI(CreateEdgeNodeRequest, ctx: ptr FFIContext[EdgeNode]):
  # `string`, not `cstring`: 0.3.0 packs the request into a CBOR blob, and a
  # cstring field would encode the pointer rather than the text (the multiaddr
  # then arrives empty). The C entry point converts at the boundary.
  proc(serviceNode: string): Future[Result[string, string]] {.async.} =
    echo "[edge] creating edge node…"
    let rng = crypto.newRng()
    let privKey = crypto.PrivateKey.random(PKScheme.Secp256k1, rng).valueOr:
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
  # 0.3.0 acquires from a fixed per-library pool that declareLibrary emits as
  # <LibType>FFIPool, rather than allocating a fresh context per call.
  var ctx = ffi.createFFIContext(EdgeNodeFFIPool).valueOr:
    let msg = "Error in createFFIContext: " & $error
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
    return nil
  ctx.userData = userData
  ffi.sendRequestToFFIThread(
    ctx, CreateEdgeNodeRequest.ffiNewReq(callback, userData, $serviceNode)
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
) {.ffiRaw: "abi = c".} =
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
) {.ffiRaw: "abi = c".} =
  proc onPush(pubsubTopic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
    echo "[edge] filter push received on ", msg.contentTopic, " (",
      msg.payload.len, " bytes)"
    emitEdgeEvent(
      "onReceivedMessage",
      $(
        %*{
          "pubsubTopic": string(pubsubTopic),
          "contentTopic": msg.contentTopic,
          "payload": string.fromBytes(msg.payload),
          "meta": base64.encode(msg.meta),
        }
      ),
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
) {.ffiRaw: "abi = c".} =
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
) {.ffiRaw: "abi = c".} =
  ## One page of history. `startNs`/`endNs`/`cursorHex` are optional ("" = unset);
  ## `forward` is "true"/"false". Returns
  ##   {"messages":[{hash,contentTopic,payload,meta,timestamp}], "cursor":"…"}
  ## with `timestamp` as a decimal string and `cursor` "" when the page is last.
  # NOTE: `Opt.some`, not std/options' `some` — StoreQueryRequest's optional
  # fields are `Opt[T]` (results), and std/options is imported here too.
  var limit =
    try: uint64(parseBiggestUInt($pageSize))
    except ValueError: DefaultPageSize
  if limit == 0'u64: limit = DefaultPageSize
  if limit > MaxPageSize: limit = MaxPageSize

  var storeReq = StoreQueryRequest(
    includeData: true,
    pubsubTopic: Opt.some(PubsubTopic($pubsubTopic)),
    contentTopics: ($contentTopics).split(","),
    paginationForward: ($forward).into(),
    paginationLimit: Opt.some(limit),
  )
  if ($startNs).len > 0:
    storeReq.startTime =
      try: Opt.some(Timestamp(parseBiggestInt($startNs)))
      except ValueError: return err("bad startNs: " & $startNs)
  if ($endNs).len > 0:
    storeReq.endTime =
      try: Opt.some(Timestamp(parseBiggestInt($endNs)))
      except ValueError: return err("bad endNs: " & $endNs)
  if ($cursorHex).len > 0:
    let cursor = hexToHash($cursorHex).valueOr:
      return err("bad cursor: " & error)
    storeReq.paginationCursor = Opt.some(cursor)

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
) {.ffiRaw: "abi = c".} =
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

# Emits nim-ffi's dispatch wrappers; must follow every {.ffiRaw.} above.
genBindings()

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
