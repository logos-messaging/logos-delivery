## Optional encryption hook for the Reliable Channel API.
##
## Applied per-segment after SDS processing on outgoing, and before
## SDS processing on incoming. No specific scheme is mandated.
##
## See: https://lip.logos.co/messaging/raw/reliable-channel-api.html

import results

type
  EncryptionError* = object of CatchableError

  EncryptFn* = proc(payload: seq[byte]): Result[seq[byte], string] {.gcsafe, raises: [].}
  DecryptFn* = proc(payload: seq[byte]): Result[seq[byte], string] {.gcsafe, raises: [].}

  EncryptionHook* = object
    encrypt*: EncryptFn
    decrypt*: DecryptFn

proc isConfigured*(self: EncryptionHook): bool =
  not self.encrypt.isNil() and not self.decrypt.isNil()

proc encrypt*(self: EncryptionHook, payload: seq[byte]): seq[byte] =
  ## Stage 4 of the outgoing pipeline (segmentation -> sds -> rate_limit_manager -> encryption).
  ## For now: passthrough — return the payload unencrypted.
  ## TODO: invoke the configured `EncryptFn` when present and surface errors.
  return payload

proc decrypt*(self: EncryptionHook, payload: seq[byte]): seq[byte] =
  ## Stage 1 of the incoming pipeline (decryption -> sds -> reassemble -> emit).
  ## For now: passthrough — return the payload as-is.
  ## TODO: invoke the configured `DecryptFn` when present and surface errors.
  return payload
