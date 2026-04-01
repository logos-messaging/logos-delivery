import chronicles, std/[net, options], results
import waku/factory/waku_conf

logScope:
  topics = "waku conf builder quic"

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

  if b.quicPort.isNone():
    return err("quic.port is not specified")

  return ok(some(QuicConf(port: b.quicPort.get())))
