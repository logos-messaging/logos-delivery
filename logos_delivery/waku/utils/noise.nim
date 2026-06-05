{.push raises: [].}

import results
import ../waku_core, ../waku_noise/noise_types, ../waku_noise/noise_utils

# Decodes a WakuMessage to a PayloadV2
# Currently, this is just a wrapper over deserializePayloadV2 and encryption/decryption is done on top (no KeyInfo)
proc decodePayloadV2*(
    message: WakuMessage
): Result[PayloadV2, cstring] {.raises: [NoiseMalformedHandshake, NoisePublicKeyError].} =
  # We check message version (only 2 is supported in this proc)
  case message.version
  of 2:
    # We attempt to decode the WakuMessage payload
    let deserializedPayload2 = deserializePayloadV2(message.payload).valueOr:
      return err("Failed to decode WakuMessage")
    return ok(deserializedPayload2)
  else:
    return err("Wrong message version while decoding payload")

# Encodes a PayloadV2 to a WakuMessage
# Currently, this is just a wrapper over serializePayloadV2 and encryption/decryption is done on top (no KeyInfo)
proc encodePayloadV2*(
    payload2: PayloadV2, contentTopic: ContentTopic = default(ContentTopic)
): Result[WakuMessage, cstring] {.
    raises: [NoiseMalformedHandshake, NoisePublicKeyError]
.} =
  # We attempt to encode the PayloadV2
  let serializedPayload2 = serializePayloadV2(payload2).valueOr:
    return err("Failed to encode PayloadV2")

  # If successful, we create and return a WakuMessage
  let msg =
    WakuMessage(payload: serializedPayload2, version: 2, contentTopic: contentTopic)

  return ok(msg)
