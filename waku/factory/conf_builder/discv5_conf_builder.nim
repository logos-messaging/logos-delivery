import chronicles, std/[net, options, sequtils], results
import ../waku_conf

logScope:
  topics = "waku conf builder discv5"

###########################
## Discv5 Config Builder ##
###########################
type Discv5ConfBuilder* = object
  enabled*: Option[bool]

  bootstrapNodes*: seq[string]
  bitsPerHop*: Option[int]
  bucketIpLimit*: Option[uint]
  enrAutoUpdate*: Option[bool]
  tableIpLimit*: Option[uint]
  udpPort*: Option[Port]

proc init*(T: type Discv5ConfBuilder): Discv5ConfBuilder =
  Discv5ConfBuilder()

proc withEnabled*(b: var Discv5ConfBuilder, enabled: bool) =
  b.enabled = some(enabled)

proc withBitsPerHop*(b: var Discv5ConfBuilder, bitsPerHop: int) =
  b.bitsPerHop = some(bitsPerHop)

proc withBucketIpLimit*(b: var Discv5ConfBuilder, bucketIpLimit: uint) =
  b.bucketIpLimit = some(bucketIpLimit)

proc withEnrAutoUpdate*(b: var Discv5ConfBuilder, enrAutoUpdate: bool) =
  b.enrAutoUpdate = some(enrAutoUpdate)

proc withTableIpLimit*(b: var Discv5ConfBuilder, tableIpLimit: uint) =
  b.tableIpLimit = some(tableIpLimit)

proc withUdpPort*(b: var Discv5ConfBuilder, udpPort: Port) =
  b.udpPort = some(udpPort)

proc withUdpPort*(b: var Discv5ConfBuilder, udpPort: uint16) =
  b.udpPort = some(Port(udpPort))

proc withBootstrapNodes*(b: var Discv5ConfBuilder, bootstrapNodes: seq[string]) =
  # TODO: validate ENRs?
  b.bootstrapNodes = concat(b.bootstrapNodes, bootstrapNodes)

proc build*(b: Discv5ConfBuilder): Result[Option[Discv5Conf], string] =
  if not b.enabled.get(false):
    return ok(none(Discv5Conf))

  return ok(
    some(
      Discv5Conf(
        bootstrapNodes: b.bootstrapNodes,
        bitsPerHop: b.bitsPerHop.get(1),
        bucketIpLimit: b.bucketIpLimit.get(2),
        enrAutoUpdate: b.enrAutoUpdate.get(true),
        tableIpLimit: b.tableIpLimit.get(10),
        udpPort: b.udpPort.get(Port(0)),
      )
    )
  )
