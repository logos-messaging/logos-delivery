import
  confutils/defs,
  libp2p/crypto/curve25519,
  libp2p/multiaddress,
  libp2p/multicodec,
  nimcrypto/utils as ncrutils

import logos_delivery/waku/waku_mix

type LightPushMixConf* = object
  destPeerAddr* {.desc: "Destination peer address with peerId.", name: "dp-addr".}:
    string

  pxAddr* {.desc: "Peer exchange address with peerId.", name: "px-addr".}: string

  port* {.desc: "Port to listen on.", defaultValue: 50000, name: "port".}: int

  numMsgs* {.desc: "Number of messages to send.", defaultValue: 1, name: "num-msgs".}:
    int

  msgIntervalMilliseconds* {.
    desc: "Interval between messages in milliseconds.",
    defaultValue: 1000,
    name: "msg-interval"
  .}: int

  minMixPoolSize* {.
    desc: "Number of mix nodes to be discovered before sending lightpush messages.",
    defaultValue: 3,
    name: "min-mix-pool-size"
  .}: int

  mixDisabled* {.
    desc: "Do not use mix for publishing.", defaultValue: false, name: "without-mix"
  .}: bool

  mixnodes* {.
    desc:
      "Multiaddress and mix-key of mix node to be statically specified in format multiaddr:mixPubKey. Argument may be repeated.",
    name: "mixnode"
  .}: seq[MixNodePubInfo]

proc parseCmdArg*(T: typedesc[MixNodePubInfo], p: string): T =
  let elements = p.split(":")
  if elements.len != 2:
    raise newException(
      ValueError, "Invalid format for mix node expected multiaddr:mixPublicKey"
    )

  let multiaddr = MultiAddress.init(elements[0]).valueOr:
    raise newException(ValueError, "Invalid multiaddress format")
  if not multiaddr.contains(multiCodec("ip4")).get():
    raise newException(
      ValueError, "Invalid format for ip address, expected a ipv4 multiaddress"
    )
  return MixNodePubInfo(
    multiaddr: elements[0], pubKey: intoCurve25519Key(ncrutils.fromHex(elements[1]))
  )
