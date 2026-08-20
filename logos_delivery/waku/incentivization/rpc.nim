import results, protobuf_serialization, protobuf_serialization/pkg/results

# Implementing the RFC:
# https://github.com/vacp2p/rfc/tree/master/content/docs/rfcs/73

type
  EligibilityProof* {.proto2.} = object
    proofOfPayment* {.fieldNumber: 1.}: Opt[seq[byte]]

  EligibilityStatus* {.proto2.} = object
    statusCode* {.fieldNumber: 1, pint, required.}: uint32
    statusDesc* {.fieldNumber: 2.}: Opt[string]
