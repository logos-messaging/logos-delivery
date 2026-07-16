import results

# Implementing the RFC:
# https://github.com/vacp2p/rfc/tree/master/content/docs/rfcs/73

type
  EligibilityProof* = object
    proofOfPayment*: Opt[seq[byte]]

  EligibilityStatus* = object
    statusCode*: uint32
    statusDesc*: Opt[string]
