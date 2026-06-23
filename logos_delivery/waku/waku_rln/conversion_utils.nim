{.push raises: [].}

import
  std/[sequtils, strutils, algorithm],
  web3,
  chronicles,
  stew/[arrayops, endians2],
  stint
import ./constants, ./protocol_types
import ../waku_keystore

export web3, chronicles, stint, constants, endians2

logScope:
  topics = "waku rln_relay conversion_utils"

proc inHex*(
    value:
      IdentityTrapdoor or IdentityNullifier or IdentitySecretHash or IDCommitment or
      MerkleNode or Nullifier or Epoch or RlnIdentifier
): string =
  var valueHex = "" #UInt256.fromBytesLE(value)
  for b in value.reversed():
    valueHex = valueHex & b.toHex()
  # We pad leading zeroes
  while valueHex.len < value.len * 2:
    valueHex = "0" & valueHex
  return toLowerAscii(valueHex)

proc encodeLengthPrefix*(input: openArray[byte]): seq[byte] =
  ## returns length prefixed version of the input
  ## with the following format [len<8>|input<var>]
  ## len: 8-byte value that represents the number of bytes in the `input`
  ## len is serialized in little-endian
  ## input: the supplied `input`
  let
    # the length should be serialized in little-endian
    len = toBytes(uint64(input.len), Endianness.littleEndian)
    output = concat(@len, @input)
  return output

proc serialize*(v: uint64): array[32, byte] =
  ## a private proc to convert uint64 to a byte seq
  ## this conversion is used in the proofGen proc

  ## converts `v` to a byte seq in little-endian order
  let bytes = toBytes(v, Endianness.littleEndian)
  var output: array[32, byte]
  discard output.copyFrom(bytes)
  return output

proc serialize*(
    idSecretHash: IdentitySecretHash,
    memIndex: MembershipIndex,
    userMessageLimit: UserMessageLimit,
    messageId: MessageId,
    externalNullifier: ExternalNullifier,
    msg: openArray[byte],
): seq[byte] =
  ## a private proc to convert RateLimitProof and the data to a byte seq
  ## this conversion is used in the proofGen proc
  ## the serialization is done as instructed in  https://github.com/kilic/rln/blob/7ac74183f8b69b399e3bc96c1ae8ab61c026dc43/src/public.rs#L146
  ## [ id_key<32> | id_index<8> | epoch<32> | signal_len<8> | signal<var> ]
  let memIndexBytes = toBytes(uint64(memIndex), Endianness.littleEndian)
  let userMessageLimitBytes = userMessageLimit.serialize()
  let messageIdBytes = messageId.serialize()
  let lenPrefMsg = encodeLengthPrefix(msg)
  let output = concat(
    @idSecretHash,
    @memIndexBytes,
    @userMessageLimitBytes,
    @messageIdBytes,
    @externalNullifier,
    lenPrefMsg,
  )
  return output

# Serializes a sequence of MerkleNodes
proc serialize*(roots: seq[MerkleNode]): seq[byte] =
  var rootsBytes: seq[byte] = @[]
  for root in roots:
    rootsBytes = concat(rootsBytes, @root)
  return rootsBytes

# Serializes a sequence of MembershipIndex's
proc serialize*(memIndices: seq[MembershipIndex]): seq[byte] =
  var memIndicesBytes = newSeq[byte]()

  # serialize the memIndices, with its length prefixed
  let len = toBytes(uint64(memIndices.len), Endianness.littleEndian)
  memIndicesBytes.add(len)

  for memIndex in memIndices:
    let memIndexBytes = toBytes(uint64(memIndex), Endianness.littleEndian)
    memIndicesBytes = concat(memIndicesBytes, @memIndexBytes)

  return memIndicesBytes

proc toEpoch*(t: uint64): Epoch =
  ## converts `t` to `Epoch` in little-endian order
  let bytes = toBytes(t, Endianness.littleEndian)
  trace "epoch bytes", bytes = bytes
  var epoch: Epoch
  discard epoch.copyFrom(bytes)
  return epoch

proc fromEpoch*(epoch: Epoch): uint64 =
  ## decodes bytes of `epoch` (in little-endian) to uint64
  let t = fromBytesLE(uint64, array[32, byte](epoch))
  return t

func `+`*(a, b: Quantity): Quantity {.borrow.}

func u256*(n: Quantity): UInt256 {.inline.} =
  n.uint64.stuint(256)

proc uint64ToField*(n: uint64): array[32, byte] =
  var output: array[32, byte]
  let bytes = toBytes(n, Endianness.littleEndian)
  output[0 ..< bytes.len] = bytes
  return output

proc UInt256ToField*(v: UInt256): array[32, byte] =
  return cast[array[32, byte]](v) # already doesn't use `result`

proc seqToField*(s: seq[byte]): array[32, byte] =
  var output: array[32, byte]
  let len = min(s.len, 32)
  for i in 0 ..< len:
    output[i] = s[i]
  return output

proc uint64ToIndex*(index: MembershipIndex, depth: int): seq[byte] =
  var output = newSeq[byte](depth)
  for i in 0 ..< depth:
    output[i] = byte((index shr i) and 1) # LSB-first bit decomposition
  return output
