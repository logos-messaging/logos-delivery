import chronicles, std/[net, sequtils], results
import ../waku_conf

logScope:
  topics = "waku conf builder rest server"

const
  DefaultRestEnabled: bool = false
  DefaultRestPort: Port = Port(8645)
  DefaultRestAdmin: bool = false

################################
## REST Server Config Builder ##
################################
type RestServerConfBuilder* = object
  enabled*: Opt[bool]

  allowOrigin*: seq[string]
  listenAddress*: Opt[IpAddress]
  port*: Opt[Port]
  admin*: Opt[bool]
  relayCacheCapacity*: Opt[uint32]

proc init*(T: type RestServerConfBuilder): RestServerConfBuilder =
  RestServerConfBuilder()

proc withEnabled*(b: var RestServerConfBuilder, enabled: bool) =
  b.enabled = Opt.some(enabled)

proc withAllowOrigin*(b: var RestServerConfBuilder, allowOrigin: seq[string]) =
  b.allowOrigin = concat(b.allowOrigin, allowOrigin)

proc withListenAddress*(b: var RestServerConfBuilder, listenAddress: IpAddress) =
  b.listenAddress = Opt.some(listenAddress)

proc withPort*(b: var RestServerConfBuilder, port: Port) =
  b.port = Opt.some(port)

proc withPort*(b: var RestServerConfBuilder, port: uint16) =
  b.port = Opt.some(Port(port))

proc withAdmin*(b: var RestServerConfBuilder, admin: bool) =
  b.admin = Opt.some(admin)

proc withRelayCacheCapacity*(b: var RestServerConfBuilder, relayCacheCapacity: uint32) =
  b.relayCacheCapacity = Opt.some(relayCacheCapacity)

proc build*(b: RestServerConfBuilder): Result[Opt[RestServerConf], string] =
  if not b.enabled.get(DefaultRestEnabled):
    return ok(Opt.none(RestServerConf))

  if b.listenAddress.isNone():
    return err("restServer.listenAddress is not specified")
  if b.relayCacheCapacity.isNone():
    return err("restServer.relayCacheCapacity is not specified")

  return ok(
    Opt.some(
      RestServerConf(
        allowOrigin: b.allowOrigin,
        listenAddress: b.listenAddress.get(),
        port: b.port.get(DefaultRestPort),
        admin: b.admin.get(DefaultRestAdmin),
        relayCacheCapacity: b.relayCacheCapacity.get(),
      )
    )
  )
