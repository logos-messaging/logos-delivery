{.push raises: [].}

import stint, chronos, web3, eth/keys
import ../../waku_core, ../../waku_keystore, ../../common/protobuf

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
type RateLimitProof* {.proto3.} = object
  ## RateLimitProof holds the public inputs to rln circuit as
  ## defined in https://hackmd.io/tMTLMYmTR5eynw2lwK9n1w?view#Public-Inputs
  ## the `proof` field carries the actual zkSNARK proof
  ## The wire fields are in field number order, because the library writes
  ## them in declaration order.
  proof* {.fieldNumber: 1, ext.}: ZKSNARK
  ## the root of Merkle tree used for the generation of the `proof`
  merkleRoot* {.fieldNumber: 2, ext.}: MerkleNode
  ## the epoch used for the generation of the `proof`
  epoch* {.fieldNumber: 3, ext.}: Epoch
  ## shareX and shareY are shares of user's identity key
  ## these shares are created using Shamir secret sharing scheme
  ## see details in https://hackmd.io/tMTLMYmTR5eynw2lwK9n1w?view#Linear-Equation-amp-SSS
  shareX* {.fieldNumber: 4, ext.}: MerkleNode
  shareY* {.fieldNumber: 5, ext.}: MerkleNode
  ## nullifier enables linking two messages published during the same epoch
  ## see details in https://hackmd.io/tMTLMYmTR5eynw2lwK9n1w?view#Nullifiers
  nullifier* {.fieldNumber: 6, ext.}: Nullifier
  ## Application specific RLN Identifier
  rlnIdentifier* {.fieldNumber: 7, ext.}: RlnIdentifier
  ## the external nullifier used for the generation of the `proof` (derived from poseidon([epoch, rln_identifier]))
  externalNullifier* {.dontSerialize.}: ExternalNullifier

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
  UnknownRoot
    ## Root not in our window even after a refresh; it may be newer than our
    ## view of the chain, so the proof cannot be judged invalid.

# Protobufs enc and init
protobufCodec(RateLimitProof)

proc init*(T: type RateLimitProof, buffer: seq[byte]): ProtobufResult[T] =
  RateLimitProof.decode(buffer)

func encode*(x: UInt32): seq[byte] =
  ## the Ethereum ABI imposes a 32 byte width for every type
  let numTargetBytes = 32 div 8
  let paddingBytes = 32 - numTargetBytes
  let paddingZeros = newSeq[byte](paddingBytes)
  paddingZeros & @(stint.toBytesBE(x))

type RegistrationHandler* =
  proc(txHash: string): void {.gcsafe, closure, raises: [Defect].}
