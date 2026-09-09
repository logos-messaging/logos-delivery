import std/json
import chronos, results, ffi
import
  logos_delivery/waku/common/base64,
  logos_delivery,
  logos_delivery/waku/waku_core/topics/content_topic,
  logos_delivery/api/types,
  ../declare_lib,
  ./channel_crypto

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

proc logosdelivery_channel_set_encryption(
    self: LogosDelivery,
    channelIdStr: string,
    encryptFn: uint64,
    decryptFn: uint64,
    userData: uint64,
): Future[Result[string, string]] {.ffi.} =
  ## `encryptFn`/`decryptFn` are `LogosDeliveryCryptoFn` pointers cast to
  ## `uint64`; `userData` is an opaque `void*`, also cast.
  ##
  ## `userData` is what lets one C function serve several channels. A
  ## function pointer carries no state, so the same `my_encrypt` registered
  ## on two channels is the same address both times and cannot tell them
  ## apart. Whatever is passed here comes back as the callback's first
  ## argument on every call, so it can point at this channel's key -- the C
  ## equivalent of a closure capture.
  ##
  ## Call this before `logosdelivery_channel_create`: the channel goes live
  ## as soon as it is created. The registration survives channel close.
  requireChannels(self, "ChannelSetEncryption"):
    return err(errMsg)

  let encrypt = toChannelCryptoFn(encryptFn, userData).valueOr:
    return err("ChannelSetEncryption failed: encrypt " & error)
  let decrypt = toChannelCryptoFn(decryptFn, userData).valueOr:
    return err("ChannelSetEncryption failed: decrypt " & error)

  self.reliableChannelManager.setChannelEncryption(
    ChannelId(channelIdStr), encrypt, decrypt
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
