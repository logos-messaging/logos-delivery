# Request utils.

{.push raises: [].}

import bearssl/rand, stew/byteutils

proc generateRequestId*(rng: ref HmacDrbgContext): string =
  var bytes: array[10, byte]
  hmacDrbgGenerate(rng[], bytes)
  return byteutils.toHex(bytes)
