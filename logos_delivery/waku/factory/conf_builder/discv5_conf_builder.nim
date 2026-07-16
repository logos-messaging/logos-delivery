import chronicles, std/[net, sequtils], results
import ../waku_conf

logScope:
  topics = "waku conf builder discv5"

const
  DefaultDiscv5Enabled*: bool = false
  DefaultDiscv5BitsPerHop: int = 1
  DefaultDiscv5BucketIpLimit: uint = 2
  DefaultDiscv5EnrAutoUpdate: bool = true
  DefaultDiscv5TableIpLimit: uint = 10
  DefaultDiscv5UdpPort: Port = Port(9000)

###########################
## Discv5 Config Builder ##
###########################
type Discv5ConfBuilder* = object
  enabled*: Opt[bool]

  bootstrapNodes*: seq[string]
  bitsPerHop*: Opt[int]
  bucketIpLimit*: Opt[uint]
  enrAutoUpdate*: Opt[bool]
  tableIpLimit*: Opt[uint]
  udpPort*: Opt[Port]

proc init*(T: type Discv5ConfBuilder): Discv5ConfBuilder =
  Discv5ConfBuilder()

proc withEnabled*(b: var Discv5ConfBuilder, enabled: bool) =
  b.enabled = Opt.some(enabled)

proc withBitsPerHop*(b: var Discv5ConfBuilder, bitsPerHop: int) =
  b.bitsPerHop = Opt.some(bitsPerHop)

proc withBucketIpLimit*(b: var Discv5ConfBuilder, bucketIpLimit: uint) =
  b.bucketIpLimit = Opt.some(bucketIpLimit)

proc withEnrAutoUpdate*(b: var Discv5ConfBuilder, enrAutoUpdate: bool) =
  b.enrAutoUpdate = Opt.some(enrAutoUpdate)

proc withTableIpLimit*(b: var Discv5ConfBuilder, tableIpLimit: uint) =
  b.tableIpLimit = Opt.some(tableIpLimit)

proc withUdpPort*(b: var Discv5ConfBuilder, udpPort: Port) =
  b.udpPort = Opt.some(udpPort)

proc withUdpPort*(b: var Discv5ConfBuilder, udpPort: uint16) =
  b.udpPort = Opt.some(Port(udpPort))

proc withBootstrapNodes*(b: var Discv5ConfBuilder, bootstrapNodes: seq[string]) =
  # TODO: validate ENRs?
  b.bootstrapNodes = concat(b.bootstrapNodes, bootstrapNodes)

proc build*(b: Discv5ConfBuilder): Result[Opt[Discv5Conf], string] =
  if not b.enabled.get(DefaultDiscv5Enabled):
    return ok(Opt.none(Discv5Conf))

  return ok(
    Opt.some(
      Discv5Conf(
        bootstrapNodes: b.bootstrapNodes,
        bitsPerHop: b.bitsPerHop.get(DefaultDiscv5BitsPerHop),
        bucketIpLimit: b.bucketIpLimit.get(DefaultDiscv5BucketIpLimit),
        enrAutoUpdate: b.enrAutoUpdate.get(DefaultDiscv5EnrAutoUpdate),
        tableIpLimit: b.tableIpLimit.get(DefaultDiscv5TableIpLimit),
        udpPort: b.udpPort.get(DefaultDiscv5UdpPort),
      )
    )
  )
