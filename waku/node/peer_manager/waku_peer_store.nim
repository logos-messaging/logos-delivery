{.push raises: [].}

import
  std/[tables, sequtils, sets, options, strutils],
  chronos,
  chronicles,
  eth/p2p/discoveryv5/enr,
  libp2p/builders,
  libp2p/peerstore,
  libp2p/crypto/curve25519

import
  ../../waku_core,
  ../../waku_enr/sharding,
  ../../waku_enr/capabilities,
  ../../common/utils/sequence,
  ../../waku_core/peers

export peerstore, builders

type
  # Keeps track of the Connectedness state of a peer
  ConnectionBook* = ref object of PeerBook[Connectedness]

  # Keeps track of the timestamp of the last failed connection attempt
  LastFailedConnBook* = ref object of PeerBook[Moment]

  # Keeps track of the number of failed connection attempts
  NumberFailedConnBook* = ref object of PeerBook[int]

  # Keeps track of when peers were disconnected in Unix timestamps
  DisconnectBook* = ref object of PeerBook[int64]

  # Keeps track of the origin of a peer
  SourceBook* = ref object of PeerBook[PeerOrigin]

  # Keeps track of the direction of a peer connection
  DirectionBook* = ref object of PeerBook[PeerDirection]

  # Keeps track of the ENR (Ethereum Node Record) of a peer
  ENRBook* = ref object of PeerBook[enr.Record]

  # Keeps track of peer shards
  ShardBook* = ref object of PeerBook[seq[uint16]]

  # Keeps track of Mix protocol public keys of peers
  MixPubKeyBook* = ref object of PeerBook[Curve25519Key]

proc getPeer*(peerStore: PeerStore, peerId: PeerId): RemotePeerInfo =
  let addresses =
    if peerStore[LastSeenBook][peerId].isSome():
      @[peerStore[LastSeenBook][peerId].get()] & peerStore[AddressBook][peerId]
    else:
      peerStore[AddressBook][peerId]

  RemotePeerInfo(
    peerId: peerId,
    addrs: addresses,
    enr:
      if peerStore[ENRBook][peerId] != default(enr.Record):
        some(peerStore[ENRBook][peerId])
      else:
        none(enr.Record),
    protocols: peerStore[ProtoBook][peerId],
    shards: peerStore[ShardBook][peerId],
    agent: peerStore[AgentBook][peerId],
    protoVersion: peerStore[ProtoVersionBook][peerId],
    publicKey: peerStore[KeyBook][peerId],
    connectedness: peerStore[ConnectionBook][peerId],
    disconnectTime: peerStore[DisconnectBook][peerId],
    origin: peerStore[SourceBook][peerId],
    direction: peerStore[DirectionBook][peerId],
    lastFailedConn: peerStore[LastFailedConnBook][peerId],
    numberFailedConn: peerStore[NumberFailedConnBook][peerId],
    mixPubKey:
      if peerStore[MixPubKeyBook][peerId] != default(Curve25519Key):
        some(peerStore[MixPubKeyBook][peerId])
      else:
        none(Curve25519Key),
  )

proc delete*(peerStore: PeerStore, peerId: PeerId) =
  # Delete all the information of a given peer.
  peerStore.del(peerId)

proc peers*(peerStore: PeerStore): seq[RemotePeerInfo] =
  let allKeys = concat(
      toSeq(peerStore[LastSeenBook].book.keys()),
      toSeq(peerStore[AddressBook].book.keys()),
      toSeq(peerStore[ProtoBook].book.keys()),
      toSeq(peerStore[KeyBook].book.keys()),
      toSeq(peerStore[ShardBook].book.keys()),
    )
    .toHashSet()

  return allKeys.mapIt(peerStore.getPeer(it))

proc addPeer*(peerStore: PeerStore, peer: RemotePeerInfo, origin = UnknownOrigin) =
  ## Storing MixPubKey even if peer is already present as this info might be new
  ## or updated.
  if peer.mixPubKey.isSome():
    trace "adding mix pub key to peer store",
      peer_id = $peer.peerId, mix_pub_key = $peer.mixPubKey.get()
    peerStore[MixPubKeyBook].book[peer.peerId] = peer.mixPubKey.get()

  ## Notice that the origin parameter is used to manually override the given peer origin.
  ## At the time of writing, this is used in waku_discv5 or waku_node (peer exchange.)
  if peerStore[AddressBook][peer.peerId] == peer.addrs and
      peerStore[KeyBook][peer.peerId] == peer.publicKey and
      peerStore[ENRBook][peer.peerId].raw.len > 0:
    let incomingEnr = peer.enr.valueOr:
      trace "peer already managed and incoming ENR is empty",
        remote_peer_id = $peer.peerId
      return

    if peerStore[ENRBook][peer.peerId].raw == incomingEnr.raw or
        peerStore[ENRBook][peer.peerId].seqNum > incomingEnr.seqNum:
      trace "peer already managed and ENR info is already saved",
        remote_peer_id = $peer.peerId
      return

  peerStore[AddressBook][peer.peerId] = peer.addrs

  var protos = peerStore[ProtoBook][peer.peerId]
  for new_proto in peer.protocols:
    ## append new discovered protocols to the current known protocols set
    if not protos.contains(new_proto):
      protos.add($new_proto)
  peerStore[ProtoBook][peer.peerId] = protos

  ## We don't care whether the item was already present in the table or not. Hence, we always discard the hasKeyOrPut's bool returned value

  discard peerStore[AgentBook].book.hasKeyOrPut(peer.peerId, peer.agent)
  discard peerStore[ProtoVersionBook].book.hasKeyOrPut(peer.peerId, peer.protoVersion)
  discard peerStore[KeyBook].book.hasKeyOrPut(peer.peerId, peer.publicKey)

  discard peerStore[ConnectionBook].book.hasKeyOrPut(peer.peerId, peer.connectedness)
  discard peerStore[DisconnectBook].book.hasKeyOrPut(peer.peerId, peer.disconnectTime)
  if origin != UnknownOrigin:
    peerStore[SourceBook][peer.peerId] = origin
  else:
    discard peerStore[SourceBook].book.hasKeyOrPut(peer.peerId, peer.origin)

  discard peerStore[DirectionBook].book.hasKeyOrPut(peer.peerId, peer.direction)
  discard
    peerStore[LastFailedConnBook].book.hasKeyOrPut(peer.peerId, peer.lastFailedConn)
  discard
    peerStore[NumberFailedConnBook].book.hasKeyOrPut(peer.peerId, peer.numberFailedConn)
  if peer.enr.isSome():
    peerStore[ENRBook][peer.peerId] = peer.enr.get()

proc setShardInfo*(peerStore: PeerStore, peerId: PeerID, shards: seq[uint16]) =
  peerStore[ShardBook][peerId] = shards

proc peers*(peerStore: PeerStore, proto: string): seq[RemotePeerInfo] =
  peerStore.peers().filterIt(it.protocols.contains(proto))

proc peers*(peerStore: PeerStore, protocolMatcher: Matcher): seq[RemotePeerInfo] =
  peerStore.peers().filterIt(it.protocols.anyIt(protocolMatcher(it)))

proc connectedness*(peerStore: PeerStore, peerId: PeerId): Connectedness =
  peerStore[ConnectionBook].book.getOrDefault(peerId, NotConnected)

proc hasShard*(peerStore: PeerStore, peerId: PeerID, cluster, shard: uint16): bool =
  peerStore[ENRBook].book.getOrDefault(peerId).containsShard(cluster, shard)

proc hasCapability*(peerStore: PeerStore, peerId: PeerID, cap: Capabilities): bool =
  peerStore[ENRBook].book.getOrDefault(peerId).supportsCapability(cap)

proc peerExists*(peerStore: PeerStore, peerId: PeerId): bool =
  peerStore[AddressBook].contains(peerId)

proc isConnected*(peerStore: PeerStore, peerId: PeerID): bool =
  # Returns `true` if the peer is connected
  peerStore.connectedness(peerId) == Connected

proc hasPeer*(peerStore: PeerStore, peerId: PeerID, proto: string): bool =
  # Returns `true` if peer is included in manager for the specified protocol
  # TODO: What if peer does not exist in the peerStore?
  peerStore.getPeer(peerId).protocols.contains(proto)

proc hasPeers*(peerStore: PeerStore, proto: string): bool =
  # Returns `true` if the peerstore has any peer for the specified protocol
  toSeq(peerStore[ProtoBook].book.values()).anyIt(it.anyIt(it == proto))

proc hasPeers*(peerStore: PeerStore, protocolMatcher: Matcher): bool =
  # Returns `true` if the peerstore has any peer matching the protocolMatcher
  toSeq(peerStore[ProtoBook].book.values()).anyIt(it.anyIt(protocolMatcher(it)))

proc getCapacity*(peerStore: PeerStore): int =
  peerStore.capacity

proc setCapacity*(peerStore: PeerStore, capacity: int) =
  peerStore.capacity = capacity

proc getWakuProtos*(peerStore: PeerStore): seq[string] =
  toSeq(peerStore[ProtoBook].book.values()).flatten().deduplicate().filterIt(
    it.startsWith("/vac/waku")
  )

proc getPeersByDirection*(
    peerStore: PeerStore, direction: PeerDirection
): seq[RemotePeerInfo] =
  return peerStore.peers.filterIt(it.direction == direction)

proc getDisconnectedPeers*(peerStore: PeerStore): seq[RemotePeerInfo] =
  return peerStore.peers.filterIt(it.connectedness != Connected)

proc getConnectedPeers*(peerStore: PeerStore): seq[RemotePeerInfo] =
  return peerStore.peers.filterIt(it.connectedness == Connected)

proc getPeersByProtocol*(peerStore: PeerStore, proto: string): seq[RemotePeerInfo] =
  return peerStore.peers.filterIt(it.protocols.contains(proto))

proc getReachablePeers*(peerStore: PeerStore): seq[RemotePeerInfo] =
  return peerStore.peers.filterIt(it.connectedness != CannotConnect)

proc getPeersByShard*(
    peerStore: PeerStore, cluster, shard: uint16
): seq[RemotePeerInfo] =
  return peerStore.peers.filterIt(
    it.enr.isSome() and it.enr.get().containsShard(cluster, shard)
  )

proc getPeersByCapability*(
    peerStore: PeerStore, cap: Capabilities
): seq[RemotePeerInfo] =
  return
    peerStore.peers.filterIt(it.enr.isSome() and it.enr.get().supportsCapability(cap))

template forEnrPeers*(
    peerStore: PeerStore,
    peerId, peerConnectedness, peerOrigin, peerEnrRecord, body: untyped,
) =
  let enrBook = peerStore[ENRBook]
  let connBook = peerStore[ConnectionBook]
  let sourceBook = peerStore[SourceBook]
  for pid, enrRecord in tables.pairs(enrBook.book):
    let peerId {.inject.} = pid
    let peerConnectedness {.inject.} = connBook.book.getOrDefault(pid, NotConnected)
    let peerOrigin {.inject.} = sourceBook.book.getOrDefault(pid, UnknownOrigin)
    let peerEnrRecord {.inject.} = enrRecord
    body
