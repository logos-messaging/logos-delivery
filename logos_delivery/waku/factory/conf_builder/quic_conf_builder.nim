import chronicles, std/net, results
import logos_delivery/waku/factory/waku_conf

logScope:
  topics = "waku conf builder quic"

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

proc build*(b: QuicConfBuilder, tcpPort: Port): Result[Opt[QuicConf], string] =
  ## An unset quic port follows the tcp port: quic is udp so the numbers don't
  ## clash, and the tcp port is already unique per host (0 auto-assigns both).
  if not b.enabled.get(false):
    return ok(Opt.none(QuicConf))

  return ok(Opt.some(QuicConf(port: b.quicPort.get(tcpPort))))
