import results, ../common/protobuf, ./rpc

protobufCodec(EligibilityProof)
proc validateDecoded(status: EligibilityStatus): ProtobufResult[void] =
  if status.statusCode == 0:
    return err(ProtobufError.missingRequiredField("status_code"))
  ok()

protobufCodec(EligibilityStatus, validateDecoded)
