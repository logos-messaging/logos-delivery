import chronicles, std/net, results
import logos_delivery/waku/factory/waku_conf

logScope:
  topics = "waku conf builder quic"

# same value as tcp default port. quic is udp, no conflict.
const DefaultQuicPort*: Port = Port(60000)

#########################
## QUIC Config Builder ##
#########################
type QuicConfBuilder* = object
  enabled*: Opt[bool]
  quicPort*: Opt[Port]

proc init*(T: type QuicConfBuilder): QuicConfBuilder =
  QuicConfBuilder()

proc withEnabled*(b: var QuicConfBuilder, enabled: bool) =
  b.enabled = Opt.some(enabled)

proc withQuicPort*(b: var QuicConfBuilder, quicPort: Port) =
  b.quicPort = Opt.some(quicPort)

proc withQuicPort*(b: var QuicConfBuilder, quicPort: uint16) =
  b.quicPort = Opt.some(Port(quicPort))

proc build*(b: QuicConfBuilder): Result[Opt[QuicConf], string] =
  if not b.enabled.get(false):
    return ok(Opt.none(QuicConf))

  return ok(Opt.some(QuicConf(port: b.quicPort.get(DefaultQuicPort))))
