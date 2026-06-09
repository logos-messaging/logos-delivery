{.push raises: [].}

import std/[options, tables, deques], stew/arrayops, stint, chronos, web3, eth/keys
import ../waku_core, ../waku_keystore, ../common/protobuf

export waku_keystore, waku_core

type RlnRelayResult*[T] = Result[T, string]

## RLN is a Nim wrapper for the data types used in zerokit RLN
type RLN* {.incompleteStruct.} = object
type RLNResult* = RlnRelayResult[ptr RLN]

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

type
  MessageValidationResult* {.pure.} = enum
    Valid
    Invalid
    Spam

  MerkleNodeResult* = RlnRelayResult[MerkleNode]
  RateLimitProofResult* = RlnRelayResult[RateLimitProof]

# Protobufs enc and init
proc init*(T: type RateLimitProof, buffer: seq[byte]): ProtoResult[T] =
  var nsp: RateLimitProof

  let pb = initProtoBuffer(buffer)

  var proof: seq[byte]
  discard ?pb.getField(1, proof)
  discard nsp.proof.copyFrom(proof)

  var merkleRoot: seq[byte]
  discard ?pb.getField(2, merkleRoot)
  discard nsp.merkleRoot.copyFrom(merkleRoot)

  var epoch: seq[byte]
  discard ?pb.getField(3, epoch)
  discard nsp.epoch.copyFrom(epoch)

  var shareX: seq[byte]
  discard ?pb.getField(4, shareX)
  discard nsp.shareX.copyFrom(shareX)

  var shareY: seq[byte]
  discard ?pb.getField(5, shareY)
  discard nsp.shareY.copyFrom(shareY)

  var nullifier: seq[byte]
  discard ?pb.getField(6, nullifier)
  discard nsp.nullifier.copyFrom(nullifier)

  var rlnIdentifier: seq[byte]
  discard ?pb.getField(7, rlnIdentifier)
  discard nsp.rlnIdentifier.copyFrom(rlnIdentifier)

  return ok(nsp)

proc encode*(nsp: RateLimitProof): ProtoBuffer =
  var output = initProtoBuffer()

  output.write3(1, nsp.proof)
  output.write3(2, nsp.merkleRoot)
  output.write3(3, nsp.epoch)
  output.write3(4, nsp.shareX)
  output.write3(5, nsp.shareY)
  output.write3(6, nsp.nullifier)
  output.write3(7, nsp.rlnIdentifier)

  output.finish3()
  return output

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
