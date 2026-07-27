import system, results, std/json, std/strutils
import stew/byteutils
import
  ../../logos_delivery/waku/common/base64,
  ../../logos_delivery/waku/waku_core/message/message,
  ../utils

type JsonMessage* = ref object # https://rfc.vac.dev/spec/36/#jsonmessage-type
  payload*: Base64String
  contentTopic*: string
  version*: uint
  timestamp*: int64
  ephemeral*: bool
  meta*: Base64String
  proof*: Base64String

func fromJsonNode*(
    T: type JsonMessage, jsonContent: JsonNode
): Result[JsonMessage, string] =
  # Visit https://rfc.vac.dev/spec/14/ for further details

  # Check if required fields exist
  if not jsonContent.hasKey("payload"):
    return err("Missing required field in WakuMessage: payload")
  if not jsonContent.hasKey("contentTopic"):
    return err("Missing required field in WakuMessage: contentTopic")

  ok(
    JsonMessage(
      payload: Base64String(jsonContent["payload"].getStr()),
      contentTopic: jsonContent["contentTopic"].getStr(),
      version: uint32(jsonContent{"version"}.getInt()),
      timestamp: (?jsonContent.getProtoInt64("timestamp")).get(0),
      ephemeral: jsonContent{"ephemeral"}.getBool(),
      meta: Base64String(jsonContent{"meta"}.getStr()),
      proof: Base64String(jsonContent{"proof"}.getStr()),
    )
  )

proc toWakuMessage*(self: JsonMessage): Result[WakuMessage, string] =
  let payload = base64.decode(self.payload).valueOr:
    return err("invalid payload format: " & error)

  let meta = base64.decode(self.meta).valueOr:
    return err("invalid meta format: " & error)

  let proof = base64.decode(self.proof).valueOr:
    return err("invalid proof format: " & error)

  ok(
    WakuMessage(
      payload: payload,
      meta: meta,
      contentTopic: self.contentTopic,
      version: uint32(self.version),
      timestamp: self.timestamp,
      ephemeral: self.ephemeral,
      proof: proof,
    )
  )

proc `%`*(value: Base64String): JsonNode =
  %(value.string)
