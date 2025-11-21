{.push raises: [].}

import bearssl/rand

import waku/utils/requests as request_utils

import ./types

proc newRequestId*(rng: ref HmacDrbgContext): RequestId =
	## Generate a new RequestId using the provided RNG.
	RequestId(request_utils.generateRequestId(rng))

{.pop.}
