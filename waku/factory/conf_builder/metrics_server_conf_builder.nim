import chronicles, std/[net, options], results
import ../waku_conf

logScope:
  topics = "waku conf builder metrics server"

###################################
## Metrics Server Config Builder ##
###################################
type MetricsServerConfBuilder* = object
  enabled*: Option[bool]

  httpAddress*: Option[IpAddress]
  httpPort*: Option[Port]
  logging*: Option[bool]

proc init*(T: type MetricsServerConfBuilder): MetricsServerConfBuilder =
  MetricsServerConfBuilder()

proc withEnabled*(b: var MetricsServerConfBuilder, enabled: bool) =
  b.enabled = some(enabled)

proc withHttpAddress*(b: var MetricsServerConfBuilder, httpAddress: IpAddress) =
  b.httpAddress = some(httpAddress)

proc withHttpPort*(b: var MetricsServerConfBuilder, httpPort: Port) =
  b.httpPort = some(httpPort)

proc withHttpPort*(b: var MetricsServerConfBuilder, httpPort: uint16) =
  b.httpPort = some(Port(httpPort))

proc withLogging*(b: var MetricsServerConfBuilder, logging: bool) =
  b.logging = some(logging)

proc build*(b: MetricsServerConfBuilder): Result[Option[MetricsServerConf], string] =
  if not b.enabled.get(false):
    return ok(none(MetricsServerConf))

  if b.httpPort.isNone():
    return err("metricsServer.httpPort is not specified")

  return ok(
    some(
      MetricsServerConf(
        httpAddress: b.httpAddress.get(static parseIpAddress("127.0.0.1")),
        httpPort: b.httpPort.get(),
        logging: b.logging.get(false),
      )
    )
  )
