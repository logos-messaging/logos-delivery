import chronicles, std/[net, options, sequtils], results
import ../waku_conf

logScope:
  topics = "waku conf builder rest server"

################################
## REST Server Config Builder ##
################################
type RestServerConfBuilder* = object
  enabled*: Option[bool]

  allowOrigin*: seq[string]
  listenAddress*: Option[IpAddress]
  port*: Option[Port]
  admin*: Option[bool]
  relayCacheCapacity*: Option[uint32]

proc init*(T: type RestServerConfBuilder): RestServerConfBuilder =
  RestServerConfBuilder()

proc withEnabled*(b: var RestServerConfBuilder, enabled: bool) =
  b.enabled = some(enabled)

proc withAllowOrigin*(b: var RestServerConfBuilder, allowOrigin: seq[string]) =
  b.allowOrigin = concat(b.allowOrigin, allowOrigin)

proc withListenAddress*(b: var RestServerConfBuilder, listenAddress: IpAddress) =
  b.listenAddress = some(listenAddress)

proc withPort*(b: var RestServerConfBuilder, port: Port) =
  b.port = some(port)

proc withPort*(b: var RestServerConfBuilder, port: uint16) =
  b.port = some(Port(port))

proc withAdmin*(b: var RestServerConfBuilder, admin: bool) =
  b.admin = some(admin)

proc withRelayCacheCapacity*(b: var RestServerConfBuilder, relayCacheCapacity: uint32) =
  b.relayCacheCapacity = some(relayCacheCapacity)

proc build*(b: RestServerConfBuilder): Result[Option[RestServerConf], string] =
  if not b.enabled.get(false):
    return ok(none(RestServerConf))

  if b.listenAddress.isNone():
    return err("restServer.listenAddress is not specified")
  if b.relayCacheCapacity.isNone():
    return err("restServer.relayCacheCapacity is not specified")

  return ok(
    some(
      RestServerConf(
        allowOrigin: b.allowOrigin,
        listenAddress: b.listenAddress.get(),
        port: b.port.get(Port(0)),
        admin: b.admin.get(false),
        relayCacheCapacity: b.relayCacheCapacity.get(),
      )
    )
  )
