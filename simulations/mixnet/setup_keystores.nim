## Generate RLN keystores from a manifest produced by register_member.rs.
##
## Reads a JSON manifest file with identity data for each node, reconstructs
## IdentityCredential from the secret hash, and saves per-node keystores.
##
## Manifest format (one JSON object per line on stdin, or a JSON array file):
##   [{"peerId": "16Uiu2...", "leafIndex": 0, "identitySecretHash": "aabb...", "rateLimit": 100}, ...]
##
## Usage: nim c -r setup_keystores.nim <manifest.json>

import std/[os, options, json, strutils]
import results
import chronicles

import
  mix_rln_spam_protection/credentials,
  mix_rln_spam_protection/types,
  mix_rln_spam_protection/rln_interface

const KeystorePassword = "mix-rln-password"

proc hexToBytes32(hex: string): Result[array[32, byte], string] =
  var h = hex
  if h.startsWith("0x") or h.startsWith("0X"):
    h = h[2 .. ^1]
  if h.len != 64:
    return err("Expected 64 hex chars, got " & $h.len)
  var output: array[32, byte]
  for i in 0 ..< 32:
    try:
      output[i] = byte(parseHexInt(h[i * 2 .. i * 2 + 1]))
    except ValueError:
      return err("Invalid hex at position " & $i)
  ok(output)

proc main() =
  let args = commandLineParams()
  if args.len < 1:
    echo "Usage: setup_keystores <manifest.json>"
    quit(1)

  let manifestPath = args[0]
  if not fileExists(manifestPath):
    echo "Manifest file not found: ", manifestPath
    quit(1)

  let manifestData = readFile(manifestPath)
  let manifest =
    try:
      parseJson(manifestData)
    except CatchableError as e:
      echo "Failed to parse manifest: ", e.msg
      quit(1)

  echo "=== RLN Keystore Setup ==="
  echo "Processing ", manifest.len, " entries from ", manifestPath
  echo ""

  for entry in manifest:
    let peerId = entry["peerId"].getStr()
    let leafIndex = MembershipIndex(entry["leafIndex"].getBiggestInt())
    let secretHex = entry["identitySecretHash"].getStr()
    let rateLimit = uint64(entry["rateLimit"].getBiggestInt())

    let idSecretBytes = hexToBytes32(secretHex).valueOr:
      echo "Invalid identity secret hex for ", peerId, ": ", error
      quit(1)

    let idCommitmentArr = poseidonHash(@[@idSecretBytes]).valueOr:
      echo "Failed to compute idCommitment for ", peerId, ": ", error
      quit(1)

    var cred: IdentityCredential
    cred.idSecretHash = IDSecretHash(idSecretBytes)
    cred.idCommitment = IDCommitment(idCommitmentArr)

    let keystorePath = "rln_keystore_" & peerId & ".json"
    let saveResult = saveKeystore(
      cred,
      KeystorePassword,
      keystorePath,
      some(leafIndex),
      some(rateLimit),
    )
    if saveResult.isErr:
      echo "Failed to save keystore for ", peerId, ": ", saveResult.error
      quit(1)

    echo "  Saved: ", keystorePath, " (index: ", leafIndex, ", limit: ", rateLimit, ")"

  echo ""
  echo "=== Setup Complete ==="

when isMainModule:
  main()
