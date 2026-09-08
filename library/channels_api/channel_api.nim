import std/json
import chronos, results, ffi
import
  logos_delivery/waku/common/base64,
  logos_delivery,
  logos_delivery/waku/waku_core/topics/content_topic,
  logos_delivery/api/types,
  ../declare_lib

proc logosdelivery_channel_create(
    self: LogosDelivery,
    channelIdStr: string,
    contentTopicStr: string,
    senderIdStr: string,
): Future[Result[string, string]] {.ffi.} =
  requireChannels(self, "ChannelCreate"):
    return err(errMsg)

  let id = self.reliableChannelManager.createReliableChannel(
    ChannelId(channelIdStr),
    ContentTopic(contentTopicStr),
    SdsParticipantID(senderIdStr),
  ).valueOr:
    return err("ChannelCreate failed: " & $error)

  return ok(string(id))

proc logosdelivery_channel_exists(
    self: LogosDelivery, channelIdStr: string
): Future[Result[string, string]] {.ffi.} =
  ## Returns `"true"` or `"false"`; a missing channel is not an error.
  requireChannels(self, "ChannelExists"):
    return err(errMsg)

  return ok($self.reliableChannelManager.channelExists(ChannelId(channelIdStr)))

proc logosdelivery_channel_send(
    self: LogosDelivery, channelIdStr: string, messageJson: string
): Future[Result[string, string]] {.ffi.} =
  ## `messageJson` carries `{ "payload": <base64>, "ephemeral": <bool> }`.
  requireChannels(self, "ChannelSend"):
    return err(errMsg)

  var jsonNode: JsonNode
  try:
    jsonNode = parseJson(messageJson)
  except Exception as e:
    return err("Failed to parse channel message JSON: " & e.msg)

  if not jsonNode.hasKey("payload"):
    return err("Missing payload field")

  let payload = base64.decode(Base64String(jsonNode["payload"].getStr())).valueOr:
    return err("invalid payload format: " & error)

  let ephemeral = jsonNode.getOrDefault("ephemeral").getBool(false)

  let requestId = (
    await self.reliableChannelManager.send(ChannelId(channelIdStr), payload, ephemeral)
  ).valueOr:
    return err("ChannelSend failed: " & $error)

  return ok($requestId)

proc logosdelivery_channel_close(
    self: LogosDelivery, channelIdStr: string
): Future[Result[string, string]] {.ffi.} =
  requireChannels(self, "ChannelClose"):
    return err(errMsg)

  (await self.reliableChannelManager.closeChannel(ChannelId(channelIdStr))).isOkOr:
    return err("ChannelClose failed: " & $error)

  return ok("")

## Per-channel encryption, registered by the host application.
##
## The callbacks travel as `uint64`: nim-ffi has no function-pointer param
## kind (`rejectRawPtrType` blocks `pointer`/`ptr T`, and a `proc` type
## crashes `codegen/c.nim`), and passing an opaque integer is what
## `{.ffiHandle.}` already does for `ref object`. The upstream fix is a
## `{.ffiCallback.}` param kind.
##
## Going through the ordinary `{.ffi.}` request path -- rather than a
## hand-written `{.exportc.}` like `logosdelivery_add_event_listener` -- is
## what makes this safe: that one runs on the foreign caller thread, so it
## would build a Nim closure on one refc heap and store it in a table owned
## by another. Here the closure is allocated, stored and invoked all on the
## FFI thread.

type
  LogosDeliveryCryptoSink = proc(output: ptr byte, outputLen: csize_t, sinkCtx: pointer) {.
    cdecl, gcsafe, raises: []
  .}
    ## Passing a sink instead of an output buffer means the application
    ## never negotiates capacity with us, and we never invoke it twice to
    ## discover a size.

  LogosDeliveryCryptoFn = proc(
    input: ptr byte,
    inputLen: csize_t,
    sink: LogosDeliveryCryptoSink,
    sinkCtx: pointer,
    userData: pointer,
  ): cint {.cdecl, gcsafe, raises: [].}
    ## Contract in `library/liblogosdelivery.h`. 0 on success.

type CryptoSinkState = object
  data: seq[byte]
  emitted: bool
  malformed: bool

proc channelCryptoSink(
    output: ptr byte, outputLen: csize_t, sinkCtx: pointer
) {.cdecl, gcsafe, raises: [].} =
  ## Appends, so a callback may emit nonce, ciphertext and tag separately.
  if sinkCtx.isNil():
    return
  let state = cast[ptr CryptoSinkState](sinkCtx)

  let n = int(outputLen)
  if n > 0 and output.isNil():
    # Latched, not just `emitted = false`: an earlier chunk may already have
    # set it, and a truncated ciphertext must not pass as success.
    state.malformed = true
    return

  state.emitted = true
  if n <= 0:
    return

  let offset = state.data.len
  state.data.setLen(offset + n)
  copyMem(addr state.data[offset], output, n)

proc toChannelCryptoFn(fn: LogosDeliveryCryptoFn, userData: pointer): ChannelCryptoFn =
  return proc(
      payload: seq[byte]
  ): Future[Result[seq[byte], string]] {.async: (raises: []).} =
    let inputPtr =
      if payload.len == 0:
        nil
      else:
        cast[ptr byte](unsafeAddr payload[0])

    var state = CryptoSinkState()
    let rc = fn(inputPtr, csize_t(payload.len), channelCryptoSink, addr state, userData)

    if rc != 0:
      return err("channel crypto callback failed with code " & $rc)
    if state.malformed:
      return err("channel crypto callback emitted a null buffer with a non-zero length")
    if not state.emitted:
      # Success without a result would put an empty payload on the wire.
      return err("channel crypto callback reported success but emitted nothing")

    return ok(state.data)

proc asCryptoFnPtr(handle: uint64): Result[LogosDeliveryCryptoFn, string] =
  ## `cast[uint]` first: a direct cast from `uint64` truncates silently on
  ## the 32-bit targets this library ships for.
  if handle == 0:
    return err("callback pointer is null")
  let asWord = cast[uint](handle)
  if uint64(asWord) != handle:
    return err("callback pointer does not fit this platform's pointer width")
  return ok(cast[LogosDeliveryCryptoFn](asWord))

proc logosdelivery_channel_set_encryption(
    self: LogosDelivery,
    channelIdStr: string,
    encryptFn: uint64,
    decryptFn: uint64,
    cryptoUserData: uint64,
): Future[Result[string, string]] {.ffi.} =
  ## `encryptFn`/`decryptFn` are `LogosDeliveryCryptoFn` pointers cast to
  ## `uint64`; `cryptoUserData` is an opaque `void*` handed back to both.
  ## The channel need not exist yet, and this survives channel close.
  requireChannels(self, "ChannelSetEncryption"):
    return err(errMsg)

  let encrypt = asCryptoFnPtr(encryptFn).valueOr:
    return err("ChannelSetEncryption failed: encrypt " & error)
  let decrypt = asCryptoFnPtr(decryptFn).valueOr:
    return err("ChannelSetEncryption failed: decrypt " & error)

  let userData = cast[pointer](cast[uint](cryptoUserData))

  self.reliableChannelManager.setChannelEncryption(
    ChannelId(channelIdStr),
    toChannelCryptoFn(encrypt, userData),
    toChannelCryptoFn(decrypt, userData),
  ).isOkOr:
    return err("ChannelSetEncryption failed: " & error)

  return ok("")

proc logosdelivery_channel_clear_encryption(
    self: LogosDelivery, channelIdStr: string
): Future[Result[string, string]] {.ffi.} =
  ## Reverts the channel to plaintext for new messages; a send already in
  ## flight keeps using the cipher, so this is not a safe point to free
  ## `userData`. See the lifetime note in `library/liblogosdelivery.h`.
  requireChannels(self, "ChannelClearEncryption"):
    return err(errMsg)

  self.reliableChannelManager.clearChannelEncryption(ChannelId(channelIdStr)).isOkOr:
    return err("ChannelClearEncryption failed: " & error)

  return ok("")
