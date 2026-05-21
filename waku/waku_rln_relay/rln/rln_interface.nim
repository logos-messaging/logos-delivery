## Nim wrappers for librln (zerokit v2.0.2, safer-ffi typed handles).
##
## Built against the `stateless` zerokit feature: tree-mutation FFI is not
## bound here because logos-delivery does not maintain a local Merkle tree
## (post-PR #3312); the WakuRlnV2 contract is the source of truth and the
## per-index Merkle path is fetched via getMerkleProof(index).
##
## Memory model: every CResult.err must be checked with `hasError` and
## consumed via `consumeError`. Every CFr / Vec_CFr / Vec_uint8 returned by
## the FFI owns memory the caller must release with the corresponding
## ffi_*_free. Use `defer:` immediately after acquisition.
##
## Wire format (v2.0.2 single-message-id):
##   RLNProof:        [ 0x00 | proof<128> | RLNProofValues(0x00) ]
##   RLNProofValues:  [ 0x00 | root<32> | external_nullifier<32> |
##                     x<32> | y<32> | nullifier<32> ]
## Total RLNProof byte size: 1 + 128 + 1 + 5*32 = 290 bytes.

import results
import ../protocol_types

{.push raises: [], gcsafe.}

# --- Types ------------------------------------------------------------------

type
  CSize = csize_t

  CFr* = object ## opaque ark_bn254::Fr handle
  FFI_RLNProof* = object
  FFI_RLNPartialProof* = object
  FFI_RLNWitnessInput* = object
  FFI_RLNPartialWitnessInput* = object
  FFI_RLNProofValues* = object

  Vec_CFr* = object
    dataPtr*: ptr CFr
    len*: CSize
    cap*: CSize

  Vec_uint8* = object
    dataPtr*: ptr uint8
    len*: CSize
    cap*: CSize

  # CResult variants — safer-ffi lowers Result<T, E> to a struct of
  # (ok: T-or-null, err: Vec_uint8-or-null). Exactly one is populated.
  CBoolResult* = object
    ok*: bool
    err*: Vec_uint8

  CResultRLNPtrVecU8* = object
    ok*: ptr RLN
    err*: Vec_uint8

  CResultCFrPtrVecU8* = object
    ok*: ptr CFr
    err*: Vec_uint8

  CResultProofPtrVecU8* = object
    ok*: ptr FFI_RLNProof
    err*: Vec_uint8

  CResultPartialProofPtrVecU8* = object
    ok*: ptr FFI_RLNPartialProof
    err*: Vec_uint8

  CResultWitnessInputPtrVecU8* = object
    ok*: ptr FFI_RLNWitnessInput
    err*: Vec_uint8

  CResultPartialWitnessInputPtrVecU8* = object
    ok*: ptr FFI_RLNPartialWitnessInput
    err*: Vec_uint8

  CResultVecCFrVecU8* = object
    ok*: Vec_CFr
    err*: Vec_uint8

  CResultVecU8VecU8* = object
    ok*: Vec_uint8
    err*: Vec_uint8

const
  FieldElementSize* = 32
  ZksnarkProofSize* = 128
  ## Single-message-id serialized RLNProof size: outer version + proof
  ## + inner RLNProofValues (inner version + 5 field elements).
  RlnProofWireSize* = 1 + ZksnarkProofSize + 1 + 5 * FieldElementSize

# FFI declarations — source of truth: vendor/zerokit/rln/src/ffi/{ffi_rln,ffi_utils}.rs

# --- RLN instance lifecycle (stateless variants) --------------------------

proc ffi_rln_new*(): CResultRLNPtrVecU8 {.importc: "ffi_rln_new", cdecl.}

proc ffi_rln_new_with_params*(
  zkey_data: ptr Vec_uint8, graph_data: ptr Vec_uint8
): CResultRLNPtrVecU8 {.importc: "ffi_rln_new_with_params", cdecl.}

proc ffi_rln_free*(rln: ptr RLN) {.importc: "ffi_rln_free", cdecl.}

# --- Keygen ---------------------------------------------------------------

proc ffi_extended_key_gen*(): Vec_CFr {.importc: "ffi_extended_key_gen", cdecl.}

proc ffi_seeded_extended_key_gen*(
  seed: ptr Vec_uint8
): Vec_CFr {.importc: "ffi_seeded_extended_key_gen", cdecl.}

# --- Witness construction -------------------------------------------------

proc ffi_rln_witness_input_new*(
  identity_secret: ptr CFr,
  user_message_limit: ptr CFr,
  message_id: ptr CFr,
  path_elements: ptr Vec_CFr,
  identity_path_index: ptr Vec_uint8,
  x: ptr CFr,
  external_nullifier: ptr CFr,
): CResultWitnessInputPtrVecU8 {.importc: "ffi_rln_witness_input_new", cdecl.}

proc ffi_rln_witness_input_free*(
  witness: ptr FFI_RLNWitnessInput
) {.importc: "ffi_rln_witness_input_free", cdecl.}

proc ffi_rln_partial_witness_input_new*(
  identity_secret: ptr CFr,
  user_message_limit: ptr CFr,
  path_elements: ptr Vec_CFr,
  identity_path_index: ptr Vec_uint8,
): CResultPartialWitnessInputPtrVecU8 {.
  importc: "ffi_rln_partial_witness_input_new", cdecl
.}

proc ffi_rln_partial_witness_input_free*(
  witness: ptr FFI_RLNPartialWitnessInput
) {.importc: "ffi_rln_partial_witness_input_free", cdecl.}

# --- Proof generation -----------------------------------------------------
# safer-ffi's repr_c::Box<T> lands on the Nim side as `ptr ptr T`. Call sites
# pass `addr handle` where `handle` is `ptr T`.

proc ffi_generate_rln_proof*(
  rln: ptr ptr RLN, witness: ptr ptr FFI_RLNWitnessInput
): CResultProofPtrVecU8 {.importc: "ffi_generate_rln_proof", cdecl.}

proc ffi_generate_partial_zk_proof*(
  rln: ptr ptr RLN, partial_witness: ptr ptr FFI_RLNPartialWitnessInput
): CResultPartialProofPtrVecU8 {.importc: "ffi_generate_partial_zk_proof", cdecl.}

proc ffi_finish_rln_proof*(
  rln: ptr ptr RLN,
  partial_proof: ptr ptr FFI_RLNPartialProof,
  witness: ptr ptr FFI_RLNWitnessInput,
): CResultProofPtrVecU8 {.importc: "ffi_finish_rln_proof", cdecl.}

# --- Verification ---------------------------------------------------------

proc ffi_verify_with_roots*(
  rln: ptr ptr RLN, proof: ptr ptr FFI_RLNProof, roots: ptr Vec_CFr, x: ptr CFr
): CBoolResult {.importc: "ffi_verify_with_roots", cdecl.}

# --- Proof serialization --------------------------------------------------

proc ffi_rln_proof_to_bytes_le*(
  proof: ptr ptr FFI_RLNProof
): CResultVecU8VecU8 {.importc: "ffi_rln_proof_to_bytes_le", cdecl.}

proc ffi_bytes_le_to_rln_proof*(
  bytes: ptr Vec_uint8
): CResultProofPtrVecU8 {.importc: "ffi_bytes_le_to_rln_proof", cdecl.}

# v2.0.2: construct an RLNProof directly from its field elements (single
# message-id variant), avoiding the manual 290-byte wire layout.
proc ffi_rln_proof_new*(
  groth16Bytes: ptr Vec_uint8,
  root: ptr CFr,
  externalNullifier: ptr CFr,
  x: ptr CFr,
  y: ptr CFr,
  nullifier: ptr CFr,
): CResultProofPtrVecU8 {.importc: "ffi_rln_proof_new", cdecl.}

proc ffi_rln_proof_free*(p: ptr FFI_RLNProof) {.importc: "ffi_rln_proof_free", cdecl.}

proc ffi_rln_partial_proof_to_bytes_le*(
  partial_proof: ptr ptr FFI_RLNPartialProof
): CResultVecU8VecU8 {.importc: "ffi_rln_partial_proof_to_bytes_le", cdecl.}

proc ffi_bytes_le_to_rln_partial_proof*(
  bytes: ptr Vec_uint8
): CResultPartialProofPtrVecU8 {.importc: "ffi_bytes_le_to_rln_partial_proof", cdecl.}

proc ffi_rln_partial_proof_free*(
  p: ptr FFI_RLNPartialProof
) {.importc: "ffi_rln_partial_proof_free", cdecl.}

# --- Proof values (extract root / x / y / nullifier from a proof) ---------

proc ffi_rln_proof_get_values*(
  proof: ptr ptr FFI_RLNProof
): ptr FFI_RLNProofValues {.importc: "ffi_rln_proof_get_values", cdecl.}

proc ffi_rln_proof_values_get_root*(
  pv: ptr ptr FFI_RLNProofValues
): ptr CFr {.importc: "ffi_rln_proof_values_get_root", cdecl.}

proc ffi_rln_proof_values_get_x*(
  pv: ptr ptr FFI_RLNProofValues
): ptr CFr {.importc: "ffi_rln_proof_values_get_x", cdecl.}

proc ffi_rln_proof_values_get_external_nullifier*(
  pv: ptr ptr FFI_RLNProofValues
): ptr CFr {.importc: "ffi_rln_proof_values_get_external_nullifier", cdecl.}

proc ffi_rln_proof_values_get_y*(
  pv: ptr ptr FFI_RLNProofValues
): CResultCFrPtrVecU8 {.importc: "ffi_rln_proof_values_get_y", cdecl.}

proc ffi_rln_proof_values_get_nullifier*(
  pv: ptr ptr FFI_RLNProofValues
): CResultCFrPtrVecU8 {.importc: "ffi_rln_proof_values_get_nullifier", cdecl.}

proc ffi_rln_proof_values_free*(
  pv: ptr FFI_RLNProofValues
) {.importc: "ffi_rln_proof_values_free", cdecl.}

# --- Slashing -------------------------------------------------------------

proc ffi_compute_id_secret*(
  share1_x: ptr CFr, share1_y: ptr CFr, share2_x: ptr CFr, share2_y: ptr CFr
): CResultCFrPtrVecU8 {.importc: "ffi_compute_id_secret", cdecl.}

# --- Primitives: CFr ------------------------------------------------------

proc ffi_cfr_zero*(): ptr CFr {.importc: "ffi_cfr_zero", cdecl.}

proc ffi_cfr_to_bytes_le*(
  cfr: ptr CFr
): Vec_uint8 {.importc: "ffi_cfr_to_bytes_le", cdecl.}

proc ffi_bytes_le_to_cfr*(
  bytes: ptr Vec_uint8
): CResultCFrPtrVecU8 {.importc: "ffi_bytes_le_to_cfr", cdecl.}

proc ffi_cfr_free*(cfr: ptr CFr) {.importc: "ffi_cfr_free", cdecl.}

# --- Primitives: Vec_CFr --------------------------------------------------

proc ffi_vec_cfr_new*(capacity: CSize): Vec_CFr {.importc: "ffi_vec_cfr_new", cdecl.}

proc ffi_vec_cfr_push*(
  v: ptr Vec_CFr, cfr: ptr CFr
) {.importc: "ffi_vec_cfr_push", cdecl.}

proc ffi_vec_cfr_len*(v: ptr Vec_CFr): CSize {.importc: "ffi_vec_cfr_len", cdecl.}

proc ffi_vec_cfr_get*(
  v: ptr Vec_CFr, i: CSize
): ptr CFr {.importc: "ffi_vec_cfr_get", cdecl.}

proc ffi_vec_cfr_free*(v: Vec_CFr) {.importc: "ffi_vec_cfr_free", cdecl.}

# --- Primitives: Vec_uint8 ------------------------------------------------

proc ffi_vec_u8_free*(v: Vec_uint8) {.importc: "ffi_vec_u8_free", cdecl.}

proc ffi_c_string_free*(s: Vec_uint8) {.importc: "ffi_c_string_free", cdecl.}

# --- Hash helpers ---------------------------------------------------------

proc ffi_hash_to_field_le*(
  input: ptr Vec_uint8
): ptr CFr {.importc: "ffi_hash_to_field_le", cdecl.}

proc ffi_poseidon_hash_pair*(
  a: ptr CFr, b: ptr CFr
): ptr CFr {.importc: "ffi_poseidon_hash_pair", cdecl.}

# --- Memory-hygiene helpers -------------------------------------------------

proc hasError*(data: Vec_uint8): bool =
  not data.dataPtr.isNil

proc asString*(data: Vec_uint8): string =
  if data.dataPtr.isNil or data.len == 0:
    return ""
  result = newString(int(data.len))
  copyMem(addr result[0], data.dataPtr, int(data.len))

proc consumeError*(prefix: string, data: Vec_uint8): string =
  ## Read an error string out of a Rust-owned Vec_uint8 AND free it.
  let msg = asString(data)
  if hasError(data):
    ffi_c_string_free(data)
  if prefix.len == 0:
    msg
  elif msg.len == 0:
    prefix
  else:
    prefix & msg

proc toVecUint8*(data: openArray[byte]): Vec_uint8 =
  ## Wrap Nim-owned bytes as a Vec_uint8 view. NOTE: the resulting Vec_uint8
  ## must NOT be passed to ffi_vec_u8_free — Nim retains ownership.
  if data.len == 0:
    return Vec_uint8(dataPtr: nil, len: 0, cap: 0)
  Vec_uint8(
    dataPtr: cast[ptr uint8](unsafeAddr data[0]),
    len: CSize(data.len),
    cap: CSize(data.len),
  )

proc vecToSeq*(data: Vec_uint8): seq[byte] =
  result = newSeq[byte](int(data.len))
  if result.len > 0:
    copyMem(addr result[0], data.dataPtr, result.len)

proc seqToFixed32*(data: openArray[byte]): RlnRelayResult[array[32, byte]] =
  if data.len != FieldElementSize:
    return err("Expected 32 bytes, got " & $data.len)
  var output: array[32, byte]
  copyMem(addr output[0], unsafeAddr data[0], FieldElementSize)
  ok(output)

proc cfrToBytesLe*(cfr: ptr CFr): RlnRelayResult[array[32, byte]] =
  let bytes = ffi_cfr_to_bytes_le(cfr)
  defer:
    ffi_vec_u8_free(bytes)
  if int(bytes.len) != FieldElementSize:
    return err("Invalid field byte length: " & $bytes.len)
  seqToFixed32(vecToSeq(bytes))

proc bytesToCfrLe*(data: openArray[byte]): RlnRelayResult[ptr CFr] =
  ## Allocate a ptr CFr from raw bytes. Caller MUST ffi_cfr_free(x).
  var vec = toVecUint8(data)
  let res = ffi_bytes_le_to_cfr(addr vec)
  if not res.ok.isNil:
    return ok(res.ok)
  err(consumeError("Failed to convert bytes to field: ", res.err))

proc cfrResultToBytes*(
    res: CResultCFrPtrVecU8, prefix: string
): RlnRelayResult[array[32, byte]] =
  ## Consume a CResultCFrPtrVecU8: read bytes if ok, free the CFr, or
  ## propagate the error (also freeing the error string).
  if res.ok.isNil:
    return err(consumeError(prefix, res.err))
  defer:
    ffi_cfr_free(res.ok)
  cfrToBytesLe(res.ok)

proc hashToFieldLe*(data: openArray[byte]): RlnRelayResult[ptr CFr] =
  ## Caller MUST ffi_cfr_free the returned ptr.
  var vec = toVecUint8(data)
  let cfr = ffi_hash_to_field_le(addr vec)
  if cfr.isNil:
    return err("Failed to hash to field")
  ok(cfr)

proc poseidonPairLe*(a, b: openArray[byte]): RlnRelayResult[array[32, byte]] =
  ## Poseidon hash of exactly two 32-byte field elements (little-endian).
  ## zerokit v2 FFI only exposes pair-input Poseidon; unary is not supported.
  let aPtr = bytesToCfrLe(a).valueOr:
    return err(error)
  defer:
    ffi_cfr_free(aPtr)
  let bPtr = bytesToCfrLe(b).valueOr:
    return err(error)
  defer:
    ffi_cfr_free(bPtr)
  let cfr = ffi_poseidon_hash_pair(aPtr, bPtr)
  if cfr.isNil:
    return err("Poseidon hash failed")
  defer:
    ffi_cfr_free(cfr)
  cfrToBytesLe(cfr)
