{.push raises: [].}

import std/[tables, deques], stew/arrayops, stint, chronos, web3, eth/keys
import ../waku_core, ../waku_keystore, ../common/protobuf, ../common/protobuf_ext

export waku_keystore, waku_core

## RLN is a Nim wrapper for the data types used in zerokit RLN
type RlnRaw* {.incompleteStruct.} = object

type
  MerkleNode* = array[32, byte]
  # Each node of the Merkle tree is a Poseidon hash which is a 32 byte value
  Nullifier* = array[32, byte]
  Epoch* = array[32, byte]
  RlnIdentifier* = array[32, byte]
  ZKSNARK* = array[128, byte]
  MessageId* = uint64
  ExternalNullifier* = array[32, byte]
  RateCommitment* = object
    idCommitment*: IDCommitment
    userMessageLimit*: UserMessageLimit

  RawRateCommitment* = seq[byte]

proc toRateCommitment*(rateCommitmentUint: UInt256): RawRateCommitment =
  return RawRateCommitment(@(rateCommitmentUint.toBytesLE()))

# Custom data types defined for waku rln relay -------------------------
type RateLimitProof* = object
  ## RateLimitProof holds the public inputs to rln circuit as
  ## defined in https://hackmd.io/tMTLMYmTR5eynw2lwK9n1w?view#Public-Inputs
  ## the `proof` field carries the actual zkSNARK proof
  proof*: ZKSNARK
  ## the root of Merkle tree used for the generation of the `proof`
  merkleRoot*: MerkleNode
  ## shareX and shareY are shares of user's identity key
  ## these shares are created using Shamir secret sharing scheme
  ## see details in https://hackmd.io/tMTLMYmTR5eynw2lwK9n1w?view#Linear-Equation-amp-SSS
  shareX*: MerkleNode
  shareY*: MerkleNode
  ## nullifier enables linking two messages published during the same epoch
  ## see details in https://hackmd.io/tMTLMYmTR5eynw2lwK9n1w?view#Nullifiers
  nullifier*: Nullifier
  ## the epoch used for the generation of the `proof`
  epoch*: Epoch
  ## Application specific RLN Identifier
  rlnIdentifier*: RlnIdentifier
  ## the external nullifier used for the generation of the `proof` (derived from poseidon([epoch, rln_identifier]))
  externalNullifier*: ExternalNullifier

type UInt40* = StUint[40]
type UInt32* = StUint[32]

type
  Field = array[32, byte] # Field element representation (256 bits)
  RLNWitnessInput* = object
    identity_secret*: Field
    user_message_limit*: Field
    message_id*: Field
    path_elements*: seq[byte]
    identity_path_index*: seq[byte]
    x*: Field
    external_nullifier*: Field

type ProofMetadata* = object
  nullifier*: Nullifier
  shareX*: MerkleNode
  shareY*: MerkleNode
  externalNullifier*: Nullifier

type MessageValidationResult* {.pure.} = enum
  Valid
  Invalid
  Spam

# Protobufs enc and init
# externalNullifier not serialized
type RateLimitProofPB {.proto2.} = object
  proof {.fieldNumber: 1, ext, required.}: ZKSNARK
  merkleRoot {.fieldNumber: 2, ext, required.}: MerkleNode
  epoch {.fieldNumber: 3, ext, required.}: Epoch
  shareX {.fieldNumber: 4, ext, required.}: MerkleNode
  shareY {.fieldNumber: 5, ext, required.}: MerkleNode
  nullifier {.fieldNumber: 6, ext, required.}: Nullifier
  rlnIdentifier {.fieldNumber: 7, ext, required.}: RlnIdentifier

proc decodeRateLimitProof(buffer: seq[byte]): ProtobufResult[RateLimitProof] =
  var pb: RateLimitProofPB
  try:
    pb = Protobuf.decode(buffer, RateLimitProofPB)
  except SerializationError:
    return err(protobuf.ProtobufError(kind: ProtobufErrorKind.DecodeFailure))
  ok(
    RateLimitProof(
      proof: pb.proof,
      merkleRoot: pb.merkleRoot,
      epoch: pb.epoch,
      shareX: pb.shareX,
      shareY: pb.shareY,
      nullifier: pb.nullifier,
      rlnIdentifier: pb.rlnIdentifier,
    )
  )

proc init*(T: type RateLimitProof, buffer: seq[byte]): ProtobufResult[T] =
  decodeRateLimitProof(buffer)

proc encode*(nsp: RateLimitProof): seq[byte] =
  Protobuf.encode(
    RateLimitProofPB(
      proof: nsp.proof,
      merkleRoot: nsp.merkleRoot,
      epoch: nsp.epoch,
      shareX: nsp.shareX,
      shareY: nsp.shareY,
      nullifier: nsp.nullifier,
      rlnIdentifier: nsp.rlnIdentifier,
    )
  )

func encode*(x: UInt32): seq[byte] =
  ## the Ethereum ABI imposes a 32 byte width for every type
  let numTargetBytes = 32 div 8
  let paddingBytes = 32 - numTargetBytes
  let paddingZeros = newSeq[byte](paddingBytes)
  paddingZeros & @(stint.toBytesBE(x))

type
  SpamHandler* =
    proc(wakuMessage: WakuMessage): void {.gcsafe, closure, raises: [Defect].}
  RegistrationHandler* =
    proc(txHash: string): void {.gcsafe, closure, raises: [Defect].}
