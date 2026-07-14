import chronicles, std/net, results
import ../waku_conf

logScope:
  topics = "waku conf builder metrics server"

const
  DefaultMetricsEnabled: bool = false
  DefaultMetricsHttpAddress: IpAddress = static parseIpAddress("127.0.0.1")
  DefaultMetricsHttpPort: Port = Port(8008)
  DefaultMetricsLogging: bool = false

###################################
## Metrics Server Config Builder ##
###################################
type MetricsServerConfBuilder* = object
  enabled*: Opt[bool]

  httpAddress*: Opt[IpAddress]
  httpPort*: Opt[Port]
  logging*: Opt[bool]

proc init*(T: type MetricsServerConfBuilder): MetricsServerConfBuilder =
  MetricsServerConfBuilder()

proc withEnabled*(b: var MetricsServerConfBuilder, enabled: bool) =
  b.enabled = Opt.some(enabled)

proc withHttpAddress*(b: var MetricsServerConfBuilder, httpAddress: IpAddress) =
  b.httpAddress = Opt.some(httpAddress)

proc withHttpPort*(b: var MetricsServerConfBuilder, httpPort: Port) =
  b.httpPort = Opt.some(httpPort)

proc withHttpPort*(b: var MetricsServerConfBuilder, httpPort: uint16) =
  b.httpPort = Opt.some(Port(httpPort))

proc withLogging*(b: var MetricsServerConfBuilder, logging: bool) =
  b.logging = Opt.some(logging)

proc build*(b: MetricsServerConfBuilder): Result[Opt[MetricsServerConf], string] =
  if not b.enabled.get(DefaultMetricsEnabled):
    return ok(Opt.none(MetricsServerConf))

  return ok(
    Opt.some(
      MetricsServerConf(
        httpAddress: b.httpAddress.get(DefaultMetricsHttpAddress),
        httpPort: b.httpPort.get(DefaultMetricsHttpPort),
        logging: b.logging.get(DefaultMetricsLogging),
      )
    )
  )
