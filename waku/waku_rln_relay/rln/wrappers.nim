import chronicles, eth/keys, stew/[arrayops, endians2], stint, results

import ./rln_interface, ../conversion_utils, ../protocol_types, ../protocol_metrics
import ../../waku_core, ../../waku_keystore

{.push raises: [], gcsafe.}

logScope:
  topics = "waku rln_relay ffi"

# Forward decl; body defined below.
proc generateExternalNullifier*(
  epoch: Epoch, rlnIdentifier: RlnIdentifier
): RlnRelayResult[ExternalNullifier]

proc toRootVec(validRoots: seq[MerkleNode]): RlnRelayResult[Vec_CFr] =
  ## Caller MUST ffi_vec_cfr_free the returned Vec_CFr.
  var roots = ffi_vec_cfr_new(csize_t(validRoots.len))
  for root in validRoots:
    let cfr = bytesToCfrLe(root).valueOr:
      ffi_vec_cfr_free(roots)
      return err("failed call to bytesToCfrLe in toRootVec: " & error)
    ffi_vec_cfr_push(addr roots, cfr)
    ffi_cfr_free(cfr)
  ok(roots)

proc proofPtrToRateLimitProof(
    proofPtr: ptr FFI_RLNProof, epoch: Epoch, rlnIdentifier: RlnIdentifier
): RlnRelayResult[RateLimitProof] =
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
  if proofValues.isNil():
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
  if rootPtr.isNil():
    return err("Failed to read proof root")
  defer:
    ffi_cfr_free(rootPtr)
  output.merkleRoot = cfrToBytesLe(rootPtr).valueOr:
    return
      err("failed call to cfrToBytesLe (root) in proofPtrToRateLimitProof: " & error)

  let xPtr = ffi_rln_proof_values_get_x(addr pvHandle)
  if xPtr.isNil():
    return err("Failed to read proof x")
  defer:
    ffi_cfr_free(xPtr)
  output.shareX = cfrToBytesLe(xPtr).valueOr:
    return
      err("failed call to cfrToBytesLe (shareX) in proofPtrToRateLimitProof: " & error)

  let yRes = ffi_rln_proof_values_get_y(addr pvHandle)
  output.shareY = cfrResultToBytes(yRes, "Failed to read proof y: ").valueOr:
    return err(error)

  let nullifierRes = ffi_rln_proof_values_get_nullifier(addr pvHandle)
  output.nullifier = cfrResultToBytes(nullifierRes, "Failed to read proof nullifier: ").valueOr:
    return err(error)

  let extNullPtr = ffi_rln_proof_values_get_external_nullifier(addr pvHandle)
  if extNullPtr.isNil():
    return err("Failed to read proof external nullifier")
  defer:
    ffi_cfr_free(extNullPtr)
  output.externalNullifier = cfrToBytesLe(extNullPtr).valueOr:
    return err(
      "failed call to cfrToBytesLe (externalNullifier) in proofPtrToRateLimitProof: " &
        error
    )

  ok(output)

proc parseCredentialVec(vec: var Vec_CFr): RlnRelayResult[IdentityCredential] =
  ## Vec_CFr order: idTrapdoor, idNullifier, idSecretHash, idCommitment.
  if int(ffi_vec_cfr_len(addr vec)) != 4:
    return err("Unexpected credential element count")

  template readField(idx: int): seq[byte] =
    let f = ffi_vec_cfr_get(addr vec, csize_t(idx))
    if f.isNil():
      return err("Missing credential field from zerokit")
    let bytes = cfrToBytesLe(f).valueOr:
      return err("failed call to cfrToBytesLe in parseCredentialVec: " & error)
    @bytes

  let idTrapdoor = readField(0)
  let idNullifier = readField(1)
  let idSecretHash = readField(2)
  let idCommitment = readField(3)

  return ok(
    IdentityCredential(
      idTrapdoor: idTrapdoor,
      idNullifier: idNullifier,
      idSecretHash: idSecretHash,
      idCommitment: idCommitment,
    )
  )

proc membershipKeyGen*(): RlnRelayResult[IdentityCredential] =
  var vec = ffi_extended_key_gen()
  defer:
    ffi_vec_cfr_free(vec)
  parseCredentialVec(vec)

proc createRLNInstanceLocal(): RLNResult =
  ## Creates a stateless RLN instance (no local Merkle tree).
  let res = ffi_rln_new()
  if res.ok.isNil():
    let msg = consumeError("error in parameters generation: ", res.err)
    info "error in parameters generation", err = msg
    return err(msg)
  ok(res.ok)

proc createRLNInstance*(): RLNResult =
  ## Wraps createRLNInstanceLocal with metrics timing.
  var res: RLNResult
  waku_rln_instance_creation_duration_seconds.nanosecondTime:
    res = createRLNInstanceLocal()
  return res

proc poseidon*(left, right: seq[byte]): RlnRelayResult[array[32, byte]] =
  ## Poseidon hash of exactly 2 inputs; zerokit v2 FFI only exposes the pair variant.
  poseidonPairLe(left, right)

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
  let leaf = poseidon(@idCommitment, @userMessageLimit).valueOr:
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
  ## externalNullifier = Poseidon(H(epoch), H(rlnIdentifier)); H = ffi_hash_to_field_le.
  let epochFr = hashToFieldLe(@epoch).valueOr:
    return err("Failed to hash epoch to field: " & error)
  defer:
    ffi_cfr_free(epochFr)
  let rlnIdFr = hashToFieldLe(@rlnIdentifier).valueOr:
    return err("Failed to hash rlnIdentifier to field: " & error)
  defer:
    ffi_cfr_free(rlnIdFr)
  let cfr = ffi_poseidon_hash_pair(epochFr, rlnIdFr)
  if cfr.isNil():
    return err("Failed to compute external nullifier")
  defer:
    ffi_cfr_free(cfr)
  cfrToBytesLe(cfr).mapErr(
    proc(e: string): string =
      "Failed to serialize external nullifier: " & e
  )

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

proc buildPathElementsVec(
    pathElements: seq[byte], depth: int
): RlnRelayResult[Vec_CFr] =
  ## Caller MUST ffi_vec_cfr_free the returned Vec_CFr.
  var vec = ffi_vec_cfr_new(csize_t(depth))
  for i in 0 ..< depth:
    let start = i * FieldElementSize
    let element = bytesToCfrLe(
      pathElements.toOpenArray(start, start + FieldElementSize - 1)
    ).valueOr:
      ffi_vec_cfr_free(vec)
      return err(
        "failed call to bytesToCfrLe (path element) in buildPathElementsVec: " & error
      )
    ffi_vec_cfr_push(addr vec, element)
    ffi_cfr_free(element)
  ok(vec)

proc buildWitnessInput(
    witness: RLNWitnessInput
): RlnRelayResult[ptr FFI_RLNWitnessInput] =
  ## ffi_rln_witness_input_new copies all inputs, so the intermediate CFrs/vecs
  ## are freed here. Caller MUST ffi_rln_witness_input_free the returned handle.
  let depth = witness.identity_path_index.len
  if witness.path_elements.len != depth * FieldElementSize:
    return err(
      "Invalid Merkle path: expected " & $(depth * FieldElementSize) & " bytes for " &
        $depth & " levels, got " & $witness.path_elements.len
    )

  var pathElementsVec = buildPathElementsVec(witness.path_elements, depth).valueOr:
    return err("failed call to buildPathElementsVec in buildWitnessInput: " & error)
  defer:
    ffi_vec_cfr_free(pathElementsVec)

  var pathIndexVec = toVecUint8(witness.identity_path_index)

  let identitySecret = bytesToCfrLe(witness.identity_secret).valueOr:
    return err(
      "failed call to bytesToCfrLe (identity_secret) in buildWitnessInput: " & error
    )
  defer:
    ffi_cfr_free(identitySecret)
  let userLimit = bytesToCfrLe(witness.user_message_limit).valueOr:
    return err(
      "failed call to bytesToCfrLe (user_message_limit) in buildWitnessInput: " & error
    )
  defer:
    ffi_cfr_free(userLimit)
  let messageIdFr = bytesToCfrLe(witness.message_id).valueOr:
    return
      err("failed call to bytesToCfrLe (message_id) in buildWitnessInput: " & error)
  defer:
    ffi_cfr_free(messageIdFr)
  let xFr = bytesToCfrLe(witness.x).valueOr:
    return err("failed call to bytesToCfrLe (x) in buildWitnessInput: " & error)
  defer:
    ffi_cfr_free(xFr)
  let externalNullifierFr = bytesToCfrLe(witness.external_nullifier).valueOr:
    return err(
      "failed call to bytesToCfrLe (external_nullifier) in buildWitnessInput: " & error
    )
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
  if witnessRes.ok.isNil():
    return err(
      consumeError("Failed to create witness in buildWitnessInput: ", witnessRes.err)
    )
  return ok(witnessRes.ok)

proc generateRlnProofWithWitness*(
    rlnInstance: ptr RLN,
    witness: RLNWitnessInput,
    epoch: Epoch,
    rlnIdentifier: RlnIdentifier,
): RlnRelayResult[RateLimitProof] =
  let witnessHandle = buildWitnessInput(witness).valueOr:
    return
      err("failed call to buildWitnessInput in generateRlnProofWithWitness: " & error)
  defer:
    ffi_rln_witness_input_free(witnessHandle)

  var ctx = rlnInstance
  var wh = witnessHandle
  let proofRes = ffi_generate_rln_proof(addr ctx, addr wh)
  if proofRes.ok.isNil():
    return err(consumeError("Failed to generate RLN proof: ", proofRes.err))
  defer:
    ffi_rln_proof_free(proofRes.ok)

  return proofPtrToRateLimitProof(proofRes.ok, epoch, rlnIdentifier)

proc buildRlnProof(
    proof: RateLimitProof, externalNullifier: ExternalNullifier
): RlnRelayResult[ptr FFI_RLNProof] =
  ## ffi_rln_proof_new copies all inputs, so the intermediate CFrs are freed
  ## here. Caller MUST ffi_rln_proof_free the returned handle.
  var groth16Vec = toVecUint8(proof.proof)
  let rootFr = bytesToCfrLe(proof.merkleRoot).valueOr:
    return err("failed call to bytesToCfrLe (root) in buildRlnProof: " & error)
  defer:
    ffi_cfr_free(rootFr)
  let extNullFr = bytesToCfrLe(externalNullifier).valueOr:
    return
      err("failed call to bytesToCfrLe (externalNullifier) in buildRlnProof: " & error)
  defer:
    ffi_cfr_free(extNullFr)
  let shareXFr = bytesToCfrLe(proof.shareX).valueOr:
    return err("failed call to bytesToCfrLe (shareX) in buildRlnProof: " & error)
  defer:
    ffi_cfr_free(shareXFr)
  let shareYFr = bytesToCfrLe(proof.shareY).valueOr:
    return err("failed call to bytesToCfrLe (shareY) in buildRlnProof: " & error)
  defer:
    ffi_cfr_free(shareYFr)
  let nullifierFr = bytesToCfrLe(proof.nullifier).valueOr:
    return err("failed call to bytesToCfrLe (nullifier) in buildRlnProof: " & error)
  defer:
    ffi_cfr_free(nullifierFr)

  let proofRes = ffi_rln_proof_new(
    addr groth16Vec, rootFr, extNullFr, shareXFr, shareYFr, nullifierFr
  )
  if proofRes.ok.isNil():
    return
      err(consumeError("Failed to build RLN proof in buildRlnProof: ", proofRes.err))
  return ok(proofRes.ok)

proc verifyRlnProof*(
    rlnInstance: ptr RLN,
    proof: RateLimitProof,
    signal: openArray[byte],
    validRoots: seq[MerkleNode],
): RlnRelayResult[bool] =
  if validRoots.len == 0:
    return err("verifyRlnProof requires at least one valid root (stateless mode)")

  # externalNullifier isn't a protobuf wire field, so a received proof has it
  # zeroed; recompute from epoch + rlnIdentifier.
  let externalNullifier = generateExternalNullifier(proof.epoch, proof.rlnIdentifier).valueOr:
    return err("failed call to generateExternalNullifier in verifyRlnProof: " & error)

  let proofHandlePtr = buildRlnProof(proof, externalNullifier).valueOr:
    return err("failed call to buildRlnProof in verifyRlnProof: " & error)
  defer:
    ffi_rln_proof_free(proofHandlePtr)

  let xFr = hashToFieldLe(signal).valueOr:
    return err("failed call to hashToFieldLe (signal) in verifyRlnProof: " & error)
  defer:
    ffi_cfr_free(xFr)

  var roots = toRootVec(validRoots).valueOr:
    return err("failed call to toRootVec in verifyRlnProof: " & error)
  defer:
    ffi_vec_cfr_free(roots)

  var ctx = rlnInstance
  var proofHandle = proofHandlePtr
  let verifyRes = ffi_verify_with_roots(addr ctx, addr proofHandle, addr roots, xFr)
  # zerokit FFI quirk: err is non-nil for all failures; free it and return the bool.
  if hasError(verifyRes.err):
    ffi_c_string_free(verifyRes.err)
  return ok(verifyRes.ok)
