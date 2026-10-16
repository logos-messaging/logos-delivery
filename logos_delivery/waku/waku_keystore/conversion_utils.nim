{.push raises: [].}

import json, results, stew/byteutils, ./protocol_types

# Encodes a KeystoreMembership credential to a byte sequence
proc encode*(credential: KeystoreMembership): seq[byte] =
  # TODO: use custom encoding, avoid wordy json
  var stringCredential: string
  # NOTE: toUgly appends to the string, doesn't replace its contents
  stringCredential.toUgly(%credential)
  return toBytes(stringCredential)

# json.to would rewrite the line info of the field symbols, which breaks stew's
# field lookup (>= 0.6.1) the first time chronicles logs an IdentityCredential.
proc toByteSeq(node: JsonNode): seq[byte] {.raises: [JsonKindError].} =
  var bytes = newSeqOfCap[byte](node.len)
  for item in node.getElems():
    bytes.add(byte(item.getInt()))
  return bytes

proc toKeystoreMembership(
    node: JsonNode
): KeystoreMembership {.raises: [KeyError, JsonKindError].} =
  let contract = node["membershipContract"]
  let credential = node["identityCredential"]
  return KeystoreMembership(
    membershipContract: MembershipContract(
      chainId: contract["chainId"].getStr(), address: contract["address"].getStr()
    ),
    treeIndex: MembershipIndex(node["treeIndex"].getBiggestInt()),
    identityCredential: IdentityCredential(
      idTrapdoor: credential["idTrapdoor"].toByteSeq(),
      idNullifier: credential["idNullifier"].toByteSeq(),
      idSecretHash: credential["idSecretHash"].toByteSeq(),
      idCommitment: credential["idCommitment"].toByteSeq(),
    ),
    userMessageLimit: UserMessageLimit(node["userMessageLimit"].getBiggestInt()),
  )

# Decodes a byte sequence to a KeystoreMembership credential
proc decode*(encodedCredential: seq[byte]): KeystoreResult[KeystoreMembership] =
  # TODO: use custom decoding, avoid wordy json
  try:
    # we parse the json decrypted keystoreCredential
    let jsonObject = parseJson(string.fromBytes(encodedCredential))
    return ok(jsonObject.toKeystoreMembership())
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
