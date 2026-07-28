import libp2p/crypto/rng
import chronos, bearssl/rand, eth/[keys, p2p]

import libp2p/crypto/crypto

var nextPort = 30303

proc localAddress*(port: int): Address =
  let port = Port(port)
  result = Address(udpPort: port, tcpPort: port, ip: parseIpAddress("127.0.0.1"))

proc setupTestNode*(
    rng: crypto.Rng, capabilities: varargs[ProtocolInfo, `protocolInfo`]
): EthereumNode =
  let
    keys1 = keys.KeyPair.random(keys.newRng()[])
    address = localAddress(nextPort)
  result = newEthereumNode(
    keys1,
    address,
    NetworkId(1),
    addAllCapabilities = false,
    bindUdpPort = address.udpPort, # Assume same as external
    bindTcpPort = address.tcpPort, # Assume same as external
    rng = rng(),
  )
  nextPort.inc
  for capability in capabilities:
    result.addCapability capability

# Copied from here: https://github.com/status-im/nim-libp2p/blob/d522537b19a532bc4af94fcd146f779c1f23bad0/tests/helpers.nim#L28
type RngWrap = object
  rng: crypto.Rng

var rngVar: RngWrap

proc getRng(): crypto.Rng =
  # TODO if `rngVar` is a threadvar like it should be, there are random and
  #      spurious compile failures on mac - this is not gcsafe but for the
  #      purpose of the tests, it's ok as long as we only use a single thread
  {.gcsafe.}:
    if rngVar.rng.isNil:
      # libp2p v2.0.0: crypto.newRng() returns the new `Rng` wrapper type;
      # construct an HmacDrbgContext directly so the field type stays as
      # `ref HmacDrbgContext` (what bearssl-style consumers expect).
      rngVar.rng = HmacDrbgContext.new()
    rngVar.rng

template rng*(): crypto.Rng =
  getRng()
