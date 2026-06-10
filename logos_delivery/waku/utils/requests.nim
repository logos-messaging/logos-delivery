# Request utils.

{.push raises: [].}

import libp2p/crypto/crypto, stew/byteutils

proc generateRequestId*(rng: crypto.Rng): string =
  var bytes: array[10, byte]
  rng.generate(bytes)
  return byteutils.toHex(bytes)
