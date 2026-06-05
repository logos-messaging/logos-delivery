{.push raises: [].}

import
  chronicles,
  json_serialization,
  json_serialization/std/options,
  json_serialization/lexer,
  results,
  libp2p/protocols/pubsub/pubsubpeer
import waku/[waku_core, node/peer_manager], ../serdes

#### Types
type WakuPeer* = object
  multiaddr*: string
  protocols*: seq[string]
  shards*: seq[uint16]
  connected*: Connectedness
  agent*: string
  origin*: PeerOrigin
  score*: Option[float64]

type WakuPeers* = seq[WakuPeer]

type PeersOfShard* = object
  shard*: uint16
  peers*: WakuPeers

type PeersOfShards* = seq[PeersOfShard]

type FilterTopic* = object
  pubsubTopic*: string
  contentTopic*: string

type FilterSubscription* = object
  peerId*: string
  filterCriteria*: seq[FilterTopic]

type PeerStats* = OrderedTable[string, OrderedTable[string, int]]
  # maps high level grouping to low level grouping of counters

#### Serialization and deserialization
proc writeValue*(
    writer: var JsonWriter[RestJson], value: WakuPeer
) {.raises: [IOError].} =
  writer.beginRecord()
  writer.writeField("multiaddr", value.multiaddr)
  writer.writeField("protocols", value.protocols)
  writer.writeField("shards", value.shards)
  writer.writeField("connected", value.connected)
  writer.writeField("agent", value.agent)
  writer.writeField("origin", value.origin)
  writer.writeField("score", value.score)
  writer.endRecord()

proc writeValue*(
    writer: var JsonWriter[RestJson], value: PeersOfShard
) {.raises: [IOError].} =
  writer.beginRecord()
  writer.writeField("shard", value.shard)
  writer.writeField("peers", value.peers)
  writer.endRecord()

proc writeValue*(
    writer: var JsonWriter[RestJson], value: FilterTopic
) {.raises: [IOError].} =
  writer.beginRecord()
  writer.writeField("pubsubTopic", value.pubsubTopic)
  writer.writeField("contentTopic", value.contentTopic)
  writer.endRecord()

proc writeValue*(
    writer: var JsonWriter[RestJson], value: FilterSubscription
) {.raises: [IOError].} =
  writer.beginRecord()
  writer.writeField("peerId", value.peerId)
  writer.writeField("filterCriteria", value.filterCriteria)
  writer.endRecord()

proc writeValue*(
    writer: var JsonWriter[RestJson], value: OrderedTable[string, int]
) {.raises: [IOError].} =
  writer.beginRecord()
  for key, value in value.pairs:
    writer.writeField(key, value)
  writer.endRecord()

proc writeValue*(
    writer: var JsonWriter[RestJson],
    value: OrderedTable[string, OrderedTable[string, int]],
) {.raises: [IOError].} =
  writer.beginRecord()
  for group, subTab in value.pairs:
    writer.writeField(group, subTab)
  writer.endRecord()

proc readValue*(
    reader: var JsonReader[RestJson], value: var WakuPeer
) {.gcsafe, raises: [SerializationError, IOError].} =
  var
    multiaddr: Option[string]
    protocols: Option[seq[string]]
    shards: Option[seq[uint16]]
    connected: Option[Connectedness]
    agent: Option[string]
    origin: Option[PeerOrigin]
    score: Option[float64]

  for fieldName in readObjectFields(reader):
    case fieldName
    of "multiaddr":
      if multiaddr.isSome():
        reader.raiseUnexpectedField("Multiple `multiaddr` fields found", "WakuPeer")
      multiaddr = some(reader.readValue(string))
    of "protocols":
      if protocols.isSome():
        reader.raiseUnexpectedField("Multiple `protocols` fields found", "WakuPeer")
      protocols = some(reader.readValue(seq[string]))
    of "shards":
      if shards.isSome():
        reader.raiseUnexpectedField("Multiple `shards` fields found", "WakuPeer")
      shards = some(reader.readValue(seq[uint16]))
    of "connected":
      if connected.isSome():
        reader.raiseUnexpectedField("Multiple `connected` fields found", "WakuPeer")
      connected = some(reader.readValue(Connectedness))
    of "agent":
      if agent.isSome():
        reader.raiseUnexpectedField("Multiple `agent` fields found", "WakuPeer")
      agent = some(reader.readValue(string))
    of "origin":
      if origin.isSome():
        reader.raiseUnexpectedField("Multiple `origin` fields found", "WakuPeer")
      origin = some(reader.readValue(PeerOrigin))
    of "score":
      if score.isSome():
        reader.raiseUnexpectedField("Multiple `score` fields found", "WakuPeer")
      score = some(reader.readValue(float64))
    else:
      unrecognizedFieldWarning(value)

  if multiaddr.isNone():
    reader.raiseUnexpectedValue("Field `multiaddr` is missing")

  if protocols.isNone():
    reader.raiseUnexpectedValue("Field `protocols` are missing")

  if shards.isNone():
    reader.raiseUnexpectedValue("Field `shards` is missing")

  if connected.isNone():
    reader.raiseUnexpectedValue("Field `connected` is missing")

  if agent.isNone():
    reader.raiseUnexpectedValue("Field `agent` is missing")

  if origin.isNone():
    reader.raiseUnexpectedValue("Field `origin` is missing")

  value = WakuPeer(
    multiaddr: multiaddr.get(),
    protocols: protocols.get(),
    shards: shards.get(),
    connected: connected.get(),
    agent: agent.get(),
    origin: origin.get(),
    score: score,
  )

proc readValue*(
    reader: var JsonReader[RestJson], value: var PeersOfShard
) {.gcsafe, raises: [SerializationError, IOError].} =
  var
    shard: Option[uint16]
    peers: Option[WakuPeers]

  for fieldName in readObjectFields(reader):
    case fieldName
    of "shard":
      if shard.isSome():
        reader.raiseUnexpectedField("Multiple `shard` fields found", "PeersOfShard")
      shard = some(reader.readValue(uint16))
    of "peers":
      if peers.isSome():
        reader.raiseUnexpectedField("Multiple `peers` fields found", "PeersOfShard")
      peers = some(reader.readValue(WakuPeers))
    else:
      unrecognizedFieldWarning(value)

  if shard.isNone():
    reader.raiseUnexpectedValue("Field `shard` is missing")

  if peers.isNone():
    reader.raiseUnexpectedValue("Field `peers` are missing")

  value = PeersOfShard(shard: shard.get(), peers: peers.get())

proc readValue*(
    reader: var JsonReader[RestJson], value: var FilterTopic
) {.gcsafe, raises: [SerializationError, IOError].} =
  var
    pubsubTopic: Option[string]
    contentTopic: Option[string]

  for fieldName in readObjectFields(reader):
    case fieldName
    of "pubsubTopic":
      if pubsubTopic.isSome():
        reader.raiseUnexpectedField(
          "Multiple `pubsubTopic` fields found", "FilterTopic"
        )
      pubsubTopic = some(reader.readValue(string))
    of "contentTopic":
      if contentTopic.isSome():
        reader.raiseUnexpectedField(
          "Multiple `contentTopic` fields found", "FilterTopic"
        )
      contentTopic = some(reader.readValue(string))
    else:
      unrecognizedFieldWarning(value)

  if pubsubTopic.isNone():
    reader.raiseUnexpectedValue("Field `pubsubTopic` is missing")

  if contentTopic.isNone():
    reader.raiseUnexpectedValue("Field `contentTopic` are missing")

  value = FilterTopic(pubsubTopic: pubsubTopic.get(), contentTopic: contentTopic.get())

proc readValue*(
    reader: var JsonReader[RestJson], value: var FilterSubscription
) {.gcsafe, raises: [SerializationError, IOError].} =
  var
    peerId: Option[string]
    filterCriteria: Option[seq[FilterTopic]]

  for fieldName in readObjectFields(reader):
    case fieldName
    of "peerId":
      if peerId.isSome():
        reader.raiseUnexpectedField(
          "Multiple `peerId` fields found", "FilterSubscription"
        )
      peerId = some(reader.readValue(string))
    of "filterCriteria":
      if filterCriteria.isSome():
        reader.raiseUnexpectedField(
          "Multiple `filterCriteria` fields found", "FilterSubscription"
        )
      filterCriteria = some(reader.readValue(seq[FilterTopic]))
    else:
      unrecognizedFieldWarning(value)

  if peerId.isNone():
    reader.raiseUnexpectedValue("Field `peerId` is missing")

  if filterCriteria.isNone():
    reader.raiseUnexpectedValue("Field `filterCriteria` are missing")

  value = FilterSubscription(peerId: peerId.get(), filterCriteria: filterCriteria.get())

proc readValue*(
    reader: var JsonReader[RestJson], value: var OrderedTable[string, int]
) {.gcsafe, raises: [SerializationError, IOError].} =
  for fieldName in readObjectFields(reader):
    let fieldValue = reader.readValue(int)
    value[fieldName] = fieldValue

proc readValue*(
    reader: var JsonReader[RestJson],
    value: var OrderedTable[string, OrderedTable[string, int]],
) {.gcsafe, raises: [SerializationError, IOError].} =
  for fieldName in readObjectFields(reader):
    let fieldValue = reader.readValue(OrderedTable[string, int])
    value[fieldName] = fieldValue

func `==`*(a, b: WakuPeer): bool {.inline.} =
  return a.multiaddr == b.multiaddr

proc init*(T: type WakuPeer, peerInfo: RemotePeerInfo): WakuPeer =
  result = WakuPeer(
    multiaddr: constructMultiaddrStr(peerInfo),
    protocols: peerInfo.protocols,
    shards: peerInfo.getShards(),
    connected: peerInfo.connectedness,
    agent: peerInfo.agent,
    origin: peerInfo.origin,
    score: none(float64),
  )

proc init*(T: type WakuPeer, pubsubPeer: PubSubPeer, pm: PeerManager): WakuPeer =
  let peerInfo = pm.getPeer(pubsubPeer.peerId)
  result = WakuPeer(
    multiaddr: constructMultiaddrStr(peerInfo),
    protocols: peerInfo.protocols,
    shards: peerInfo.getShards(),
    connected: peerInfo.connectedness,
    agent: peerInfo.agent,
    origin: peerInfo.origin,
    score: some(pubsubPeer.score),
  )

proc add*(
    peers: var WakuPeers,
    multiaddr: string,
    protocol: string,
    shards: seq[uint16],
    connected: Connectedness,
    agent: string,
    origin: PeerOrigin,
) =
  var peer: WakuPeer = WakuPeer(
    multiaddr: multiaddr,
    protocols: @[protocol],
    shards: shards,
    connected: connected,
    agent: agent,
    origin: origin,
  )
  let idx = peers.find(peer)

  if idx < 0:
    peers.add(peer)
  else:
    peers[idx].protocols.add(protocol)
