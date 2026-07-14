import results

import logos_delivery/waku/incentivization/rpc

proc init*(T: type EligibilityStatus, isEligible: bool): T =
  if isEligible:
    EligibilityStatus(statusCode: uint32(200), statusDesc: Opt.some("OK"))
  else:
    EligibilityStatus(statusCode: uint32(402), statusDesc: Opt.some("Payment Required"))
