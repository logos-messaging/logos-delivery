import chronicles, std/[net, options], results
import logos_delivery/waku/factory/waku_conf

logScope:
  topics = "waku conf builder quic"

# same value as tcp default port. quic is udp, no conflict.
const DefaultQuicPort*: Port = Port(60000)

#########################
## QUIC Config Builder ##
#########################
type QuicConfBuilder* = object
  enabled*: Option[bool]
  quicPort*: Option[Port]

proc init*(T: type QuicConfBuilder): QuicConfBuilder =
  QuicConfBuilder()

proc withEnabled*(b: var QuicConfBuilder, enabled: bool) =
  b.enabled = some(enabled)

proc withQuicPort*(b: var QuicConfBuilder, quicPort: Port) =
  b.quicPort = some(quicPort)

proc withQuicPort*(b: var QuicConfBuilder, quicPort: uint16) =
  b.quicPort = some(Port(quicPort))

proc build*(b: QuicConfBuilder): Result[Option[QuicConf], string] =
  if not b.enabled.get(false):
    return ok(none(QuicConf))

  return ok(some(QuicConf(port: b.quicPort.get(DefaultQuicPort))))
