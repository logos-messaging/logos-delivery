{.push raises: [].}

import json, results, stew/byteutils, ./protocol_types

# Encodes a KeystoreMembership credential to a byte sequence
proc encode*(credential: KeystoreMembership): seq[byte] =
  # TODO: use custom encoding, avoid wordy json
  var stringCredential: string
  # NOTE: toUgly appends to the string, doesn't replace its contents
  stringCredential.toUgly(%credential)
  return toBytes(stringCredential)

# Decodes a byte sequence to a KeystoreMembership credential
proc decode*(encodedCredential: seq[byte]): KeystoreResult[KeystoreMembership] =
  # TODO: use custom decoding, avoid wordy json
  try:
    # we parse the json decrypted keystoreCredential
    let jsonObject = parseJson(string.fromBytes(encodedCredential))
    return ok(to(jsonObject, KeystoreMembership))
  except JsonParsingError:
    return err(
      AppKeystoreError(
        kind: KeystoreJsonError,
        msg: "error during decoding credentials: " & getCurrentExceptionMsg(),
      )
    )
  except Exception: #parseJson raises Exception
    return err(
      AppKeystoreError(
        kind: KeystoreOsError,
        msg: "error in conversion_utils decode: " & getCurrentExceptionMsg(),
      )
    )
