import results, ../common/protobuf

# Implementing the RFC:
# https://github.com/vacp2p/rfc/tree/master/content/docs/rfcs/73

type
  EligibilityProof* {.proto3.} = object
    proofOfPayment* {.fieldNumber: 1.}: Opt[seq[byte]]

  EligibilityStatus* {.proto3.} = object
    statusCode* {.fieldNumber: 1, pint.}: uint32
    statusDesc* {.fieldNumber: 2.}: Opt[string]
