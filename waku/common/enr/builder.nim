{.push raises: [].}

import
  std/[options, net],
  results,
  eth/keys as eth_keys,
  eth/enr/enr,
  libp2p/crypto/crypto as libp2p_crypto

import ./typed_record

## Builder

type EnrBuilder* = object
  seqNumber: uint64
  privateKey: eth_keys.PrivateKey
  ipAddress: Opt[IpAddress]
  tcpPort: Opt[Port]
  udpPort: Opt[Port]
  fields: seq[FieldPair]

proc init*(T: type EnrBuilder, key: eth_keys.PrivateKey, seqNum: uint64 = 1): T =
  EnrBuilder(
    seqNumber: seqNum,
    privateKey: key,
    ipAddress: Opt.none(IpAddress),
    tcpPort: Opt.none(Port),
    udpPort: Opt.none(Port),
    fields: newSeq[FieldPair](),
  )

proc init*(T: type EnrBuilder, key: libp2p_crypto.PrivateKey, seqNum: uint64 = 1): T =
  # TODO: Inconvenient runtime assertion. Move this assertion to compile time
  if key.scheme != PKScheme.Secp256k1:
    raise newException(Defect, "invalid private key scheme")

  let
    bytes = key.getRawBytes().expect("Private key is valid")
    privateKey =
      eth_keys.PrivateKey.fromRaw(bytes).expect("Raw private key is of valid length")

  EnrBuilder.init(key = privateKey, seqNum = seqNum)

proc addFieldPair*(builder: var EnrBuilder, pair: FieldPair) =
  builder.fields.add(pair)

proc addFieldPair*[V](builder: var EnrBuilder, key: string, value: V) =
  builder.addFieldPair(toFieldPair(key, value))

proc build*(builder: EnrBuilder): EnrResult[enr.Record] =
  # Note that nim-eth's `Record.init` does not deduplicate the field pairs.
  # See: https://github.com/status-im/nim-eth/blob/4b22fcd/eth/enr/enr.nim#L143-L144
  enr.Record.init(
    seqNum = builder.seqNumber,
    pk = builder.privateKey,
    ip = builder.ipAddress,
    tcpPort = builder.tcpPort,
    udpPort = builder.udpPort,
    extraFields = builder.fields,
  )

## Builder extension: IP address and TCP/UDP ports

proc addAddressAndPorts(
    builder: var EnrBuilder, ip: IpAddress, tcpPort, udpPort: Option[Port]
) =
  builder.ipAddress = Opt.some(ip)
  builder.tcpPort = tcpPort.toOpt()
  builder.udpPort = udpPort.toOpt()

proc addPorts(builder: var EnrBuilder, tcp, udp: Option[Port]) =
  # Based on: https://github.com/status-im/nim-eth/blob/4b22fcd/eth/enr/enr.nim#L166
  builder.tcpPort = tcp.toOpt()
  builder.udpPort = udp.toOpt()

proc withIpAddressAndPorts*(
    builder: var EnrBuilder,
    ipAddr = none(IpAddress),
    tcpPort = none(Port),
    udpPort = none(Port),
) =
  if ipAddr.isSome():
    addAddressAndPorts(builder, ipAddr.get(), tcpPort, udpPort)
  else:
    addPorts(builder, tcpPort, udpPort)
