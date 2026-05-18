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

proc isConfigured*(h: EncryptionHook): bool =
  not h.encrypt.isNil() and not h.decrypt.isNil()
