## No-op encryption hook. Useful as the default when no encryption is
## configured by the application.

import results
import ./encryption

proc noopEncrypt(payload: seq[byte]): Result[seq[byte], string] {.gcsafe, raises: [].} =
  return ok(payload)

proc noopDecrypt(payload: seq[byte]): Result[seq[byte], string] {.gcsafe, raises: [].} =
  return ok(payload)

proc init*(T: typedesc[EncryptionHook]): T =
  return T(encrypt: noopEncrypt, decrypt: noopDecrypt)
