import std/json
import
  chronicles,
  options,
  eth/keys,
  stew/[arrayops, byteutils, endians2],
  stint,
  results,
  std/[sequtils, strutils, tables]

import ./rln_interface, ../conversion_utils, ../protocol_types, ../protocol_metrics
import ../../waku_core, ../../waku_keystore

logScope:
  topics = "waku rln_relay ffi"

proc membershipKeyGen*(): RlnRelayResult[IdentityCredential] =
  ## generates a IdentityCredential that can be used for the registration into the rln membership contract
  ## Returns an error if the key generation fails

  # keysBufferPtr will hold the generated identity tuple i.e., trapdoor, nullifier, secret hash and commitment
  var
    keysBuffer: Buffer
    keysBufferPtr = addr(keysBuffer)
    done = key_gen(keysBufferPtr, true)

  # check whether the keys are generated successfully
  if (done == false):
    return err("error in key generation")

  if (keysBuffer.len != 4 * 32):
    return err("keysBuffer is of invalid length")

  var generatedKeys = cast[ptr array[4 * 32, byte]](keysBufferPtr.`ptr`)[]
  # the public and secret keys together are 64 bytes

  # TODO define a separate proc to decode the generated keys to the secret and public components
  var
    idTrapdoor: array[32, byte]
    idNullifier: array[32, byte]
    idSecretHash: array[32, byte]
    idCommitment: array[32, byte]
  for (i, x) in idTrapdoor.mpairs:
    x = generatedKeys[i + 0 * 32]
  for (i, x) in idNullifier.mpairs:
    x = generatedKeys[i + 1 * 32]
  for (i, x) in idSecretHash.mpairs:
    x = generatedKeys[i + 2 * 32]
  for (i, x) in idCommitment.mpairs:
    x = generatedKeys[i + 3 * 32]

  var identityCredential = IdentityCredential(
    idTrapdoor: @idTrapdoor,
    idNullifier: @idNullifier,
    idSecretHash: @idSecretHash,
    idCommitment: @idCommitment,
  )

  return ok(identityCredential)

type RlnTreeConfig = ref object of RootObj
  cache_capacity: int
  mode: string
  compression: bool
  flush_every_ms: int

type RlnConfig = ref object of RootObj
  resources_folder: string
  tree_config: RlnTreeConfig

proc `%`(c: RlnConfig): JsonNode =
  ## wrapper around the generic JObject constructor.
  ## We don't need to have a separate proc for the tree_config field
  let tree_config =
    %{
      "cache_capacity": %c.tree_config.cache_capacity,
      "mode": %c.tree_config.mode,
      "compression": %c.tree_config.compression,
      "flush_every_ms": %c.tree_config.flush_every_ms,
    }
  return %[("resources_folder", %c.resources_folder), ("tree_config", %tree_config)]

proc createRLNInstanceLocal(): RLNResult =
  ## generates an instance of RLN
  ## An RLN instance supports both zkSNARKs logics and Merkle tree data structure and operations
  ## Returns an error if the instance creation fails

  let rln_config = RlnConfig(
    resources_folder: "tree_height_/",
    tree_config: RlnTreeConfig(
      cache_capacity: 15_000,
      mode: "high_throughput",
      compression: false,
      flush_every_ms: 500,
    ),
  )

  var serialized_rln_config = $(%rln_config)

  var
    rlnInstance: ptr RLN
    merkleDepth: csize_t = uint(20)
    configBuffer =
      serialized_rln_config.toOpenArrayByte(0, serialized_rln_config.high).toBuffer()

  # create an instance of RLN
  let res = new_circuit(merkleDepth, addr configBuffer, addr rlnInstance)
  # check whether the circuit parameters are generated successfully
  if (res == false):
    info "error in parameters generation"
    return err("error in parameters generation")
  return ok(rlnInstance)

proc createRLNInstance*(): RLNResult =
  ## Wraps the rln instance creation for metrics
  ## Returns an error if the instance creation fails
  var res: RLNResult
  waku_rln_instance_creation_duration_seconds.nanosecondTime:
    res = createRLNInstanceLocal()
  return res

proc sha256*(data: openArray[byte]): RlnRelayResult[MerkleNode] =
  ## a thin layer on top of the Nim wrapper of the sha256 hasher
  var
    hashInputBuffer = data.toBuffer()
    outputBuffer: Buffer # will holds the hash output

  trace "sha256 hash input buffer length", bufflen = hashInputBuffer.len
  let hashSuccess = sha256(addr hashInputBuffer, addr outputBuffer, true)

  # check whether the hash call is done successfully
  if not hashSuccess:
    return err("error in sha256 hash")

  let output = cast[ptr MerkleNode](outputBuffer.`ptr`)[]

  return ok(output)

proc poseidon*(data: seq[seq[byte]]): RlnRelayResult[array[32, byte]] =
  ## a thin layer on top of the Nim wrapper of the poseidon hasher
  var inputBytes = serialize(data)
  var
    hashInputBuffer = inputBytes.toBuffer()
    outputBuffer: Buffer # will holds the hash output

  let hashSuccess = poseidon(addr hashInputBuffer, addr outputBuffer, true)

  # check whether the hash call is done successfully
  if not hashSuccess:
    return err("error in poseidon hash")

  let output = cast[ptr array[32, byte]](outputBuffer.`ptr`)[]

  return ok(output)

proc toLeaf*(rateCommitment: RateCommitment): RlnRelayResult[seq[byte]] =
  let idCommitment = rateCommitment.idCommitment
  var userMessageLimit: array[32, byte]
  try:
    discard userMessageLimit.copyFrom(
      toBytes(rateCommitment.userMessageLimit, Endianness.littleEndian)
    )
  except CatchableError:
    return err(
      "could not convert the user message limit to bytes: " & getCurrentExceptionMsg()
    )
  let leaf = poseidon(@[@idCommitment, @userMessageLimit]).valueOr:
    return err("could not convert the rate commitment to a leaf")
  var retLeaf = newSeq[byte](leaf.len)
  for i in 0 ..< leaf.len:
    retLeaf[i] = leaf[i]
  return ok(retLeaf)

proc toLeaves*(rateCommitments: seq[RateCommitment]): RlnRelayResult[seq[seq[byte]]] =
  var leaves = newSeq[seq[byte]]()
  for rateCommitment in rateCommitments:
    let leaf = toLeaf(rateCommitment).valueOr:
      return err("could not convert the rate commitment to a leaf: " & $error)
    leaves.add(leaf)
  return ok(leaves)

proc extractMetadata*(proof: RateLimitProof): RlnRelayResult[ProofMetadata] =
  let epochHash = sha256(@(proof.epoch)).valueOr:
    return err("Failed to compute epoch hash: " & error)
  let rlnIdentifierHash = sha256(@(proof.rlnIdentifier)).valueOr:
    return err("Failed to compute rln identifier hash: " & error)
  let externalNullifier = poseidon(@[@(epochHash), @(rlnIdentifierHash)]).valueOr:
    return err("Failed to compute external nullifier: " & error)
  return ok(
    ProofMetadata(
      nullifier: proof.nullifier,
      shareX: proof.shareX,
      shareY: proof.shareY,
      externalNullifier: externalNullifier,
    )
  )
