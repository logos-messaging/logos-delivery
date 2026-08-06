import protobuf_serialization, protobuf_serialization/pkg/results
import ../common/protobuf, ./rpc

# Codec for EligibilityProof

proc encode*(epRpc: EligibilityProof): seq[byte] =
  Protobuf.encode(epRpc)

proc decodeEligibilityProof(buffer: seq[byte]): ProtobufResult[EligibilityProof] =
  try:
    ok(Protobuf.decode(buffer, EligibilityProof))
  except SerializationError:
    err(protobuf.ProtobufError(kind: ProtobufErrorKind.DecodeFailure))

proc decode*(T: type EligibilityProof, buffer: seq[byte]): ProtobufResult[T] =
  decodeEligibilityProof(buffer)

# Codec for EligibilityStatus

proc encode*(esRpc: EligibilityStatus): seq[byte] =
  Protobuf.encode(esRpc)

proc decodeEligibilityStatus(buffer: seq[byte]): ProtobufResult[EligibilityStatus] =
  try:
    ok(Protobuf.decode(buffer, EligibilityStatus))
  except SerializationError:
    err(protobuf.ProtobufError(kind: ProtobufErrorKind.DecodeFailure))

proc decode*(T: type EligibilityStatus, buffer: seq[byte]): ProtobufResult[T] =
  decodeEligibilityStatus(buffer)
