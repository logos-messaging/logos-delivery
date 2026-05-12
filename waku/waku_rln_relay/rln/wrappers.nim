import
  chronicles,
  options,
  eth/keys,
  stew/[arrayops, byteutils, endians2],
  stint,
  results,
  std/[sequtils, strutils, tables],
  nimcrypto/keccak as keccak

import ./rln_interface, ../conversion_utils, ../protocol_types, ../protocol_metrics
import ../../waku_core, ../../waku_keystore

{.push raises: [], gcsafe.}

logScope:
  topics = "waku rln_relay ffi"

# ===========================================================================
# Internal helpers (private — wrappers.nim only)
# ===========================================================================

# Forward declaration: `buildProofBytesLe` and `proofPtrToRateLimitProof`
# below use this, but its body is defined further down with the rest of the
# public API.
proc generateExternalNullifier*(
  epoch: Epoch, rlnIdentifier: RlnIdentifier
): RlnRelayResult[ExternalNullifier]

proc toRootVec(validRoots: seq[MerkleNode]): RlnRelayResult[Vec_CFr] =
  ## Build a Vec_CFr from a list of Merkle roots for ffi_verify_with_roots.
  ## Caller MUST ffi_vec_cfr_free the returned Vec_CFr.
  var roots = ffi_vec_cfr_new(csize_t(validRoots.len))
  for root in validRoots:
    let cfr = bytesToCfrLe(root).valueOr:
      ffi_vec_cfr_free(roots)
      return err(error)
    ffi_vec_cfr_push(addr roots, cfr)
    ffi_cfr_free(cfr)
  ok(roots)

proc buildProofBytesLe(
    proof: RateLimitProof, rlnIdentifier: RlnIdentifier
): RlnRelayResult[seq[byte]] =
  ## Serialize a RateLimitProof into the v2.0.1 wire format expected by
  ## ffi_bytes_le_to_rln_proof. Layout (290 bytes):
  ##   [ 0x00 | proof<128> | 0x00 | root<32> | ext_nullifier<32>
  ##           | shareX<32> | shareY<32> | nullifier<32> ]
  let externalNullifier = generateExternalNullifier(proof.epoch, rlnIdentifier).valueOr:
    return err("Failed to compute external nullifier: " & error)

  var encoded = newSeq[byte](RlnProofWireSize)
  var offset = 0

  encoded[offset] = 0x00'u8; inc offset  # outer RLNProof version

  copyMem(addr encoded[offset], unsafeAddr proof.proof[0], ZksnarkProofSize)
  offset += ZksnarkProofSize

  encoded[offset] = 0x00'u8; inc offset  # inner RLNProofValues version

  copyMem(addr encoded[offset], unsafeAddr proof.merkleRoot[0], FieldElementSize)
  offset += FieldElementSize
  copyMem(addr encoded[offset], unsafeAddr externalNullifier[0], FieldElementSize)
  offset += FieldElementSize
  copyMem(addr encoded[offset], unsafeAddr proof.shareX[0], FieldElementSize)
  offset += FieldElementSize
  copyMem(addr encoded[offset], unsafeAddr proof.shareY[0], FieldElementSize)
  offset += FieldElementSize
  copyMem(addr encoded[offset], unsafeAddr proof.nullifier[0], FieldElementSize)

  ok(encoded)

proc proofPtrToRateLimitProof(
    proofPtr: ptr FFI_RLNProof,
    epoch: Epoch,
    rlnIdentifier: RlnIdentifier,
): RlnRelayResult[RateLimitProof] =
  ## Extract a RateLimitProof from an FFI proof handle. Uses
  ## ffi_rln_proof_to_bytes_le for the zkSNARK bytes (offset 1, after the
  ## outer version byte) and the proof-values getters for root/x/y/null.
  var proofHandle = proofPtr
  let proofBytesRes = ffi_rln_proof_to_bytes_le(addr proofHandle)
  if hasError(proofBytesRes.err):
    return err(consumeError("Failed to serialize proof: ", proofBytesRes.err))
  defer:
    ffi_vec_u8_free(proofBytesRes.ok)

  let serialized = vecToSeq(proofBytesRes.ok)
  if serialized.len < RlnProofWireSize:
    return err("Serialized proof too short: " & $serialized.len)

  let proofValues = ffi_rln_proof_get_values(addr proofHandle)
  if proofValues.isNil:
    return err("Failed to extract proof values")
  defer:
    ffi_rln_proof_values_free(proofValues)

  var output: RateLimitProof
  output.epoch = epoch
  output.rlnIdentifier = rlnIdentifier

  # zkSNARK bytes: skip the leading version byte, take 128.
  copyMem(addr output.proof[0], unsafeAddr serialized[1], ZksnarkProofSize)

  var pvHandle = proofValues

  let rootPtr = ffi_rln_proof_values_get_root(addr pvHandle)
  if rootPtr.isNil:
    return err("Failed to read proof root")
  defer:
    ffi_cfr_free(rootPtr)
  output.merkleRoot = cfrToBytesLe(rootPtr).valueOr:
    return err(error)

  let xPtr = ffi_rln_proof_values_get_x(addr pvHandle)
  if xPtr.isNil:
    return err("Failed to read proof x")
  defer:
    ffi_cfr_free(xPtr)
  output.shareX = cfrToBytesLe(xPtr).valueOr:
    return err(error)

  let yRes = ffi_rln_proof_values_get_y(addr pvHandle)
  output.shareY = cfrResultToBytes(yRes, "Failed to read proof y: ").valueOr:
    return err(error)

  let nullifierRes = ffi_rln_proof_values_get_nullifier(addr pvHandle)
  output.nullifier =
    cfrResultToBytes(nullifierRes, "Failed to read proof nullifier: ").valueOr:
      return err(error)

  # externalNullifier is derived from epoch + rlnIdentifier; recompute for
  # consistency with the existing protocol_types.nim contract.
  let extNullifier = generateExternalNullifier(epoch, rlnIdentifier).valueOr:
    return err("Failed to compute external nullifier: " & error)
  output.externalNullifier = extNullifier

  ok(output)

proc parseCredentialVec(
    vec: var Vec_CFr
): RlnRelayResult[IdentityCredential] =
  ## ffi_extended_key_gen returns a Vec_CFr of exactly 4 elements:
  ## [ idTrapdoor, idNullifier, idSecretHash, idCommitment ].
  if int(ffi_vec_cfr_len(addr vec)) != 4:
    return err("Unexpected credential element count")

  template readField(idx: int): seq[byte] =
    let f = ffi_vec_cfr_get(addr vec, csize_t(idx))
    if f.isNil:
      return err("Missing credential field from zerokit")
    let bytes = cfrToBytesLe(f).valueOr:
      return err(error)
    @bytes

  let idTrapdoor = readField(0)
  let idNullifier = readField(1)
  let idSecretHash = readField(2)
  let idCommitment = readField(3)

  ok(
    IdentityCredential(
      idTrapdoor: idTrapdoor,
      idNullifier: idNullifier,
      idSecretHash: idSecretHash,
      idCommitment: idCommitment,
    )
  )

# ===========================================================================
# Public API (signatures preserved from v0.9 wrappers)
# ===========================================================================

proc membershipKeyGen*(): RlnRelayResult[IdentityCredential] =
  ## generates a IdentityCredential that can be used for the registration into the rln membership contract
  ## Returns an error if the key generation fails
  let res = ffi_extended_key_gen()
  if hasError(res.err):
    return err(consumeError("Key generation failed: ", res.err))
  var vec = res.ok
  defer:
    ffi_vec_cfr_free(vec)
  parseCredentialVec(vec)

proc createRLNInstanceLocal(): RLNResult =
  ## generates an instance of RLN
  ## An RLN instance supports zkSNARK proof generation and verification.
  ## In stateless mode (logos-delivery default since PR #3312), no internal
  ## Merkle tree is allocated; the contract is the source of truth and the
  ## per-message path is supplied via getMerkleProof(index).
  let res = ffi_rln_new()
  if res.ok.isNil:
    let msg = consumeError("error in parameters generation: ", res.err)
    info "error in parameters generation", err = msg
    return err(msg)
  ok(res.ok)

proc createRLNInstance*(): RLNResult =
  ## Wraps the rln instance creation for metrics
  ## Returns an error if the instance creation fails
  var res: RLNResult
  waku_rln_instance_creation_duration_seconds.nanosecondTime:
    res = createRLNInstanceLocal()
  return res

proc poseidon*(data: seq[seq[byte]]): RlnRelayResult[array[32, byte]] =
  ## a thin layer on top of the Nim wrapper of the poseidon hasher.
  ##
  ## zerokit v2 FFI only exposes pair-input Poseidon. logos-delivery's only
  ## callers (toLeaf, generateExternalNullifier) pass exactly two inputs;
  ## any other arity is rejected here rather than silently producing a
  ## different hash than the v0.9 multi-input proc would have.
  if data.len != 2:
    return err(
      "Only 2-input Poseidon hashing is supported by zerokit v2 FFI, got " &
        $data.len & " inputs"
    )
  poseidonPairLe(data[0], data[1])

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

proc generateExternalNullifier*(
    epoch: Epoch, rlnIdentifier: RlnIdentifier
): RlnRelayResult[ExternalNullifier] =
  ## External nullifier = Poseidon(keccak(epoch), keccak(rlnIdentifier)).
  ## The keccak pre-hash is preserved from the v0.9 behaviour so that the
  ## value matches what previously-registered identities and verifiers expect.
  let epochHash = keccak.keccak256.digest(@(epoch))
  let rlnIdentifierHash = keccak.keccak256.digest(@(rlnIdentifier))
  let externalNullifier = poseidon(@[@(epochHash), @(rlnIdentifierHash)]).valueOr:
    return err("Failed to compute external nullifier: " & error)
  return ok(externalNullifier)

proc extractMetadata*(proof: RateLimitProof): RlnRelayResult[ProofMetadata] =
  let externalNullifier = generateExternalNullifier(proof.epoch, proof.rlnIdentifier).valueOr:
    return err("Failed to compute external nullifier: " & error)
  return ok(
    ProofMetadata(
      nullifier: proof.nullifier,
      shareX: proof.shareX,
      shareY: proof.shareY,
      externalNullifier: externalNullifier,
    )
  )

# ===========================================================================
# New high-level proof gen / verify (replaces v0.9 raw FFI call sites)
# ===========================================================================

proc generateRlnProofWithWitness*(
    rlnInstance: ptr RLN,
    witness: RLNWitnessInput,
    epoch: Epoch,
    rlnIdentifier: RlnIdentifier,
): RlnRelayResult[RateLimitProof] =
  ## Build a v2.0.1 witness from the v0.9-shaped RLNWitnessInput record and
  ## generate a proof. Replaces the raw `generate_proof_with_witness` FFI
  ## call. The caller is responsible for computing `witness.x` (signal hash)
  ## and `witness.external_nullifier` (same scheme as
  ## generateExternalNullifier above).
  ##
  ## path_elements is depth*32 bytes of concatenated field elements;
  ## identity_path_index is depth bytes of 0/1 direction bits.
  let depth = witness.identity_path_index.len
  if witness.path_elements.len != depth * FieldElementSize:
    return err(
      "Invalid Merkle path: expected " & $(depth * FieldElementSize) &
        " bytes for " & $depth & " levels, got " & $witness.path_elements.len
    )

  # Build the Vec_CFr of path elements.
  var pathElementsVec = ffi_vec_cfr_new(csize_t(depth))
  defer:
    ffi_vec_cfr_free(pathElementsVec)

  for i in 0 ..< depth:
    let start = i * FieldElementSize
    let element = bytesToCfrLe(
      witness.path_elements.toOpenArray(start, start + FieldElementSize - 1)
    ).valueOr:
      return err(error)
    ffi_vec_cfr_push(addr pathElementsVec, element)
    ffi_cfr_free(element)

  var pathIndexVec = toVecUint8(witness.identity_path_index)

  let identitySecret = bytesToCfrLe(witness.identity_secret).valueOr:
    return err(error)
  defer:
    ffi_cfr_free(identitySecret)

  let userLimit = bytesToCfrLe(witness.user_message_limit).valueOr:
    return err(error)
  defer:
    ffi_cfr_free(userLimit)

  let messageIdFr = bytesToCfrLe(witness.message_id).valueOr:
    return err(error)
  defer:
    ffi_cfr_free(messageIdFr)

  let xFr = bytesToCfrLe(witness.x).valueOr:
    return err(error)
  defer:
    ffi_cfr_free(xFr)

  let externalNullifierFr = bytesToCfrLe(witness.external_nullifier).valueOr:
    return err(error)
  defer:
    ffi_cfr_free(externalNullifierFr)

  let witnessRes = ffi_rln_witness_input_new(
    identitySecret,
    userLimit,
    messageIdFr,
    addr pathElementsVec,
    addr pathIndexVec,
    xFr,
    externalNullifierFr,
  )
  if witnessRes.ok.isNil:
    return err(consumeError("Failed to create witness: ", witnessRes.err))
  defer:
    ffi_rln_witness_input_free(witnessRes.ok)

  var ctx = rlnInstance
  var witnessHandle = witnessRes.ok
  let proofRes = ffi_generate_rln_proof(addr ctx, addr witnessHandle)
  if proofRes.ok.isNil:
    return err(consumeError("Failed to generate RLN proof: ", proofRes.err))
  defer:
    ffi_rln_proof_free(proofRes.ok)

  proofPtrToRateLimitProof(proofRes.ok, epoch, rlnIdentifier)

proc verifyRlnProof*(
    rlnInstance: ptr RLN,
    proof: RateLimitProof,
    signal: openArray[byte],
    validRoots: seq[MerkleNode],
): RlnRelayResult[bool] =
  ## Verify an RLN proof against a set of valid roots from the contract's
  ## recentRoots ring buffer. validRoots must be non-empty; in stateless mode
  ## there is no internal Merkle tree so ffi_verify_rln_proof is not available.
  if validRoots.len == 0:
    return err("verifyRlnProof requires at least one valid root (stateless mode)")

  let proofBytes = buildProofBytesLe(proof, proof.rlnIdentifier).valueOr:
    return err(error)

  var proofVec = toVecUint8(proofBytes)
  let proofRes = ffi_bytes_le_to_rln_proof(addr proofVec)
  if proofRes.ok.isNil:
    return
      err(consumeError("Failed to deserialize proof for verification: ", proofRes.err))
  defer:
    ffi_rln_proof_free(proofRes.ok)

  let xFr = hashToFieldLe(signal).valueOr:
    return err(error)
  defer:
    ffi_cfr_free(xFr)

  var ctx = rlnInstance
  var proofHandle = proofRes.ok

  var roots = toRootVec(validRoots).valueOr:
    return err("Failed to build root vector: " & error)
  defer:
    ffi_vec_cfr_free(roots)

  let verifyRes = ffi_verify_with_roots(addr ctx, addr proofHandle, addr roots, xFr)
  if hasError(verifyRes.err):
    return err(consumeError("Proof verification failed: ", verifyRes.err))
  ok(verifyRes.ok)
