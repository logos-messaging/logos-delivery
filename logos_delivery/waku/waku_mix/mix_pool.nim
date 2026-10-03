## The mix pool. It keeps each mix node that this node knows, with a copy of its
## addresses, protocols, ENR and shards. It keeps one hop address for each pool
## member. A delete in the peer store of the node does not remove a mix node,
## change its hop or end its role as an exit.

{.push raises: [].}

import
  std/[sequtils, tables],
  chronicles,
  chronos,
  metrics,
  results,
  libp2p/crypto/curve25519,
  libp2p/crypto/[crypto, secp],
  libp2p_mix,
  libp2p_mix/mix_protocol,
  libp2p_mix/multiaddr as mix_multiaddr,
  libp2p/[multiaddress, peerid, peerinfo, peerstore, peeraddrpolicy, switch, wire]
from eth/p2p/discoveryv5/enr import Record

import
  logos_delivery/waku/node/peer_manager,
  logos_delivery/waku/node/peer_manager/waku_peer_store,
  logos_delivery/waku/node/delivery_dialer,
  logos_delivery/waku/waku_enr/sharding,
  ./protocol_metrics

export peeraddrpolicy

logScope:
  topics = "waku mix pool"

const
  MixPoolLoopInterval = chronos.seconds(15) ## The time between two pool passes.
  MixFailureBackoff = chronos.minutes(30)
  DiscoveredMixNodeTtl = chronos.hours(1)
  MaxDiscoveredMixNodes = 1000

type
  MixNodeSource {.pure.} = enum
    Discovered ## A peer record with a mix key.
    Configured ## `--mixnode` or a preset.

  KnownMixNode = object
    ## It is a pool member while it has a hop address and no recorded dial
    ## failure.
    source: MixNodeSource
    mixPubKey: Curve25519Key
    libp2pPubKey: SkPublicKey
    lastDialed: Opt[MultiAddress]
      ## The remote address of the last outbound connection to the node. A failed
      ## dial clears it, because the node possibly moved.
    stored: seq[MultiAddress] ## The last peer store addresses that a hop can carry.
    configured: seq[MultiAddress] ## The addresses of `--mixnode` or a preset.
    # The exit choice reads these copies of the peer store.
    protocols: seq[string]
    enr: Record
    shards: seq[uint16]
    lastSeen: Moment
      ## The time of the last peer record with a mix key, successful dial or
      ## connection.
    failedAt: Opt[Moment] ## The time of the last recorded dial failure.

type MixPool* = ref object
  peerManager: PeerManager
  policy: PeerAddressPolicy ## Accepts or rejects each hop address.
  known: Table[PeerId, KnownMixNode] ## Each mix node that the pool knows.
  members: PeerStore ## One hop address for each pool member.
  nodePool: MixNodePool ## The pool over `members` that nim-libp2p-mix reads.
  dials: Table[PeerId, Future[bool].Raising([CancelledError])]
    ## The last dial of each peer. A later attempt joins it.
  dialsStopped: bool
    ## True from `stop` to `start`. Then no send starts a dial, and no dial event
    ## counts.
  loop: Future[void]
  # The settings are public for tests.
  poolLoopInterval*: Duration = MixPoolLoopInterval
  failureBackoff*: Duration = MixFailureBackoff
    ## A discovered node with a failed dial stays off paths for this time.
  discoveredTtl*: Duration = DiscoveredMixNodeTtl
    ## A discovered node leaves after this time with no peer record with a mix
    ## key, no successful dial and no connection.
  maxDiscovered*: int = MaxDiscoveredMixNodes ## The limit of discovered nodes.

const publicDirectAddressPolicy* = proc(ma: MultiAddress): bool {.gcsafe, raises: [].} =
  ## Accepts a public address that is not a relay route. Only a relay client can
  ## dial a relay route.
  ma.isPublicMA() and not ma.isCircuitRelayMA()

func mixAddressPolicy*(allowAllAddresses: bool): PeerAddressPolicy =
  ## The address policy of `--mix-allow-all-addresses`.
  if allowAllAddresses: defaultAddressPolicy else: publicDirectAddressPolicy

proc accepts*(pool: MixPool, address: MultiAddress): bool =
  ## True when the policy accepts `address`, and `address` has no wildcard host
  ## or zero port. For a relay route, the policy must also accept the address of
  ## the relay, because the previous hop dials it.
  let base = mix_multiaddr.getBaseTransport(address).valueOr:
    return false
  return
    pool.policy.dialableAddrs([address]).len == 1 and
    pool.policy.dialableAddrs([base]).len == 1

proc usableHopAddress(pool: MixPool, peerId: PeerId, address: MultiAddress): bool =
  ## True when the address policy and the encoder both accept `address`.
  return
    pool.accepts(address) and mix_multiaddr.multiAddrToBytes(peerId, address).isOk()

func store(pool: MixPool): PeerStore =
  pool.peerManager.switch.peerStore

proc hopAddresses(pool: MixPool, peerId: PeerId): seq[MultiAddress] =
  ## The addresses of `peerId` that a hop can carry, from the copies of the pool.
  ## The last dialed address comes first, then the last peer store addresses,
  ## then the configured addresses.
  var candidates: seq[MultiAddress]
  pool.known.withValue(peerId, node):
    if node.lastDialed.isSome():
      candidates.add(node.lastDialed.get())
    candidates.add(node.stored)
    candidates.add(node.configured)
  var carried: seq[MultiAddress]
  for address in candidates:
    if address notin carried and pool.usableHopAddress(peerId, address):
      carried.add(address)
  return carried

proc hopAddress(pool: MixPool, peerId: PeerId): Opt[MultiAddress] =
  ## The address that a hop through `peerId` encodes.
  let carried = pool.hopAddresses(peerId)
  if carried.len == 0:
    return Opt.none(MultiAddress)
  return Opt.some(carried[0])

proc poolEntry(pool: MixPool, peerId: PeerId): Opt[MixPubInfo] =
  ## The pool entry for `peerId`.
  let address = pool.hopAddress(peerId).valueOr:
    return Opt.none(MixPubInfo)
  pool.known.withValue(peerId, node):
    if node.failedAt.isNone():
      return
        Opt.some(MixPubInfo.init(peerId, address, node.mixPubKey, node.libp2pPubKey))
  return Opt.none(MixPubInfo)

proc len*(pool: MixPool): int =
  ## The number of pool members.
  pool.members[MixPubKeyBook].len

func nodePool*(pool: MixPool): MixNodePool =
  ## The pool that nim-libp2p-mix draws paths from.
  pool.nodePool

proc refreshPeer(pool: MixPool, peerId: PeerId) =
  ## Makes the pool entry of `peerId` agree with the known node.
  let members = pool.members
  let hop = pool.poolEntry(peerId).valueOr:
    if peerId in members[MixPubKeyBook]:
      discard members[MixPubKeyBook].del(peerId)
      trace "Mix peer left the pool", peerId = peerId
    discard members[AddressBook].del(peerId)
    discard members[KeyBook].del(peerId)
    return

  let key = crypto.PublicKey(scheme: Secp256k1, skkey: hop.libp2pPubKey)
  if members[KeyBook][peerId] != key:
    members[KeyBook][peerId] = key
  if members[AddressBook][peerId] != @[hop.multiAddr]:
    # `set` keeps an `Infinite` entry that the new list leaves out.
    discard members[AddressBook].del(peerId)
    members[AddressBook].set(peerId, @[hop.multiAddr], AddressConfidence.Infinite)
  # The key comes last, so a pool change handler sees a complete entry.
  let joined = peerId notin members[MixPubKeyBook]
  if members[MixPubKeyBook][peerId] != hop.mixPubKey:
    members[MixPubKeyBook][peerId] = hop.mixPubKey
    if joined:
      trace "Mix peer joined the pool", peerId = peerId, hop = $hop.multiAddr

proc copyPeerInfo(pool: MixPool, peerId: PeerId) =
  ## Copies the addresses, protocols, ENR and shards of `peerId` from the peer
  ## store. The pool keeps its copy of a book when the peer store has no entry.
  let store = pool.store
  let stored = store[AddressBook][peerId]
  let protocols = store[ProtoBook][peerId]
  let record = store[ENRBook][peerId]
  let shards = store[ShardBook][peerId]
  pool.known.withValue(peerId, node):
    if stored.len > 0:
      # A record with only addresses that a hop cannot carry empties this copy.
      node.stored = stored.filterIt(pool.usableHopAddress(peerId, it))
    if protocols.len > 0:
      if pool.peerManager.switch.isConnected(peerId):
        # Identify writes the full list on a connection, so it replaces the copy.
        node.protocols = protocols
      else:
        # After a delete, the book has only the protocols of a discovery
        # record, such as the mix service of a kademlia record.
        for protocol in protocols:
          if protocol notin node.protocols:
            node.protocols.add(protocol)
    if record.raw.len > 0:
      node.enr = record
    if shards.len > 0:
      node.shards = shards

proc copyLastDialed(pool: MixPool, peerId: PeerId) =
  ## Copies the remote address of the last outbound connection to `peerId`. Only
  ## a new node and a new outbound connection copy it, so the address that a
  ## failed dial cleared does not come back with the next peer record.
  let lastDialed = pool.store[LastSeenOutboundBook][peerId]
  pool.known.withValue(peerId, node):
    if lastDialed.isSome():
      node.lastDialed = Opt.some(lastDialed.get().stripPeerId())

proc hasProtocol*(pool: MixPool, peerId: PeerId, protocol: string): bool =
  ## True when the last known protocols of the mix node `peerId` have `protocol`.
  pool.known.withValue(peerId, node):
    return protocol in node.protocols
  return false

proc hasShard*(pool: MixPool, peerId: PeerId, cluster, shard: uint16): bool =
  ## True when the last known ENR or shards of the mix node `peerId` have `shard`
  ## of `cluster`.
  pool.known.withValue(peerId, node):
    return node.enr.containsShard(cluster, shard) or shard in node.shards
  return false

proc evictAtLimit(pool: MixPool) =
  ## Removes one discovered node when the pool has `maxDiscovered` of them. A
  ## node that is not a pool member goes first. Then the node with the oldest
  ## `lastSeen` goes.
  let members = pool.members[MixPubKeyBook]
  var count = 0
  var removed: Opt[PeerId]
  var removedRank: (bool, Moment)
  for peerId, node in pool.known:
    if node.source == MixNodeSource.Configured:
      continue
    count.inc()
    let rank = (peerId in members, node.lastSeen)
    if removed.isNone() or rank < removedRank:
      removed = Opt.some(peerId)
      removedRank = rank
  if count < pool.maxDiscovered or removed.isNone():
    return
  pool.known.del(removed.get())
  trace "Mix peer removed at the limit of discovered nodes", peerId = removed.get()
  pool.refreshPeer(removed.get())

proc learn(pool: MixPool, peerId: PeerId) =
  ## Adds or updates the known node `peerId` when the peer store has its mix key.
  ## When the peer store deletes the key, the pool keeps the node.
  let mixPubKey = pool.store[MixPubKeyBook][peerId]
  if mixPubKey == default(Curve25519Key) or
      peerId == pool.peerManager.switch.peerInfo.peerId:
    return
  if peerId notin pool.known:
    # The peer id contains the libp2p key of the hop.
    var libp2pPubKey: crypto.PublicKey
    if not peerId.extractPublicKey(libp2pPubKey) or libp2pPubKey.scheme != Secp256k1:
      return
    pool.evictAtLimit()
    pool.known[peerId] =
      KnownMixNode(source: MixNodeSource.Discovered, libp2pPubKey: libp2pPubKey.skkey)
    pool.copyLastDialed(peerId)
  pool.known.withValue(peerId, node):
    # The last key wins, also for a configured node.
    node.mixPubKey = mixPubKey
    node.lastSeen = Moment.now()
  pool.copyPeerInfo(peerId)
  pool.refreshPeer(peerId)

proc addBookHandlers(pool: MixPool) =
  ## Adds a handler to each peer store book that the pool copies. The peer store
  ## cannot remove the handlers. A handler reads only these books, because
  ## `PeerStore.del` iterates over the books and a read of a missing book adds a
  ## book.
  let store = pool.store
  store[MixPubKeyBook].addHandler(
    proc(peerId: PeerId) {.gcsafe, raises: [].} =
      pool.learn(peerId)
  )
  let onPeerInfo = proc(peerId: PeerId) {.gcsafe, raises: [].} =
    if peerId in pool.known:
      pool.copyPeerInfo(peerId)
      pool.refreshPeer(peerId)
  store[AddressBook].addHandler(onPeerInfo)
  store[LastSeenOutboundBook].addHandler(
    proc(peerId: PeerId) {.gcsafe, raises: [].} =
      if peerId in pool.known:
        pool.copyLastDialed(peerId)
        pool.refreshPeer(peerId)
  )
  store[ProtoBook].addHandler(onPeerInfo)
  store[ENRBook].addHandler(onPeerInfo)
  store[ShardBook].addHandler(onPeerInfo)

proc addChangeHandler*(pool: MixPool, handler: PeerBookChangeHandler) =
  ## Calls `handler` when a peer joins or leaves the pool.
  pool.members[MixPubKeyBook].addHandler(handler)

proc add*(pool: MixPool, info: MixPubInfo) =
  ## Adds a configured mix node. The node stays for the life of the pool. The
  ## call also writes the node to the peer store, so that this node can dial it.
  if info.peerId == pool.peerManager.switch.peerInfo.peerId:
    return
  # A node that the pool knows keeps its copies.
  var node = pool.known.getOrDefault(info.peerId)
  node.source = MixNodeSource.Configured
  node.failedAt = Opt.none(Moment)
  if info.multiAddr notin node.configured:
    node.configured.add(info.multiAddr)
  node.mixPubKey = info.mixPubKey
  node.libp2pPubKey = info.libp2pPubKey
  node.lastSeen = Moment.now()
  pool.known[info.peerId] = node
  MixNodePool.new(pool.store).add(info)
  pool.refreshPeer(info.peerId)

proc failed*(pool: MixPool, peerId: PeerId): bool =
  ## True while the mix node `peerId` is off paths after a failed dial. Public
  ## for tests.
  pool.known.withValue(peerId, node):
    return node.failedAt.isSome()
  return false

proc countFailure*(pool: MixPool, peerId: PeerId) =
  ## Records a failed dial of `peerId`. The pool no longer uses the last dialed
  ## address, because the node possibly moved. A discovered node also leaves
  ## paths for `failureBackoff`, and a configured node stays. Public for tests.
  pool.known.withValue(peerId, node):
    node.lastDialed = Opt.none(MultiAddress)
    if node.source == MixNodeSource.Discovered:
      node.failedAt = Opt.some(Moment.now())
      logos_delivery_mix_dial_failures.inc()
  do:
    return
  pool.refreshPeer(peerId)

proc countFailureIfConnected(pool: MixPool, peerId: PeerId) =
  ## Records a failed dial of `peerId` only while this node has a connection to
  ## another peer. With no connection, the network of this node possibly does not
  ## work.
  if not pool.peerManager.switch.connectedPeers().anyIt(it != peerId):
    trace "Mix dial failure not counted, this node has no other connection",
      peerId = peerId
    return
  pool.countFailure(peerId)

proc dialPeer(
    pool: MixPool, peerId: PeerId
): Future[bool] {.async: (raises: [CancelledError]).} =
  ## Dials `peerId` at its hop addresses and records the result. An existing
  ## connection counts as a success.
  let addresses = pool.hopAddresses(peerId)
  if addresses.len == 0:
    return false
  try:
    await pool.peerManager.switch.connect(peerId, addresses).wait(DefaultDialTimeout)
  except AsyncTimeoutError:
    debug "Mix peer dial timed out", peerId = peerId, addresses = $addresses
    pool.countFailureIfConnected(peerId)
    return false
  except DialFailedError as exc:
    debug "Mix peer dial failed",
      peerId = peerId, addresses = $addresses, error = exc.msg
    # A full connection limit of this node tells nothing about the peer.
    if not exc.connectionLimitReached():
      pool.countFailureIfConnected(peerId)
    return false
  pool.known.withValue(peerId, node):
    node.failedAt = Opt.none(Moment)
    node.lastSeen = Moment.now()
  pool.refreshPeer(peerId)
  debug "Mix peer dial succeeded", peerId = peerId
  return true

proc dial*(pool: MixPool, peerId: PeerId): Future[bool].Raising([CancelledError]) =
  ## Returns the running dial of `peerId`, or starts a new one. A second libp2p
  ## dial of the same peer waits for the first one, and then dials again when
  ## there is no connection.
  pool.dials.withValue(peerId, running):
    if not running[].finished():
      return running[]
  var done: seq[PeerId]
  for id, running in pool.dials:
    if running.finished():
      done.add(id)
  for id in done:
    pool.dials.del(id)
  let started = pool.dialPeer(peerId)
  pool.dials[peerId] = started
  return started

proc stopped*(pool: MixPool): bool =
  ## True from `stop` to `start`.
  pool.dialsStopped

proc isHopDial(
    pool: MixPool, peerId: PeerId, addrs: seq[MultiAddress], protos: seq[string]
): bool =
  ## True for a mix stream dial to a pool peer at its hop address while this node
  ## has no connection to that peer. nim-libp2p-mix makes such a dial for the
  ## first hop of a send, the next hop of a packet, and the first hop of a reply.
  ## A failed dial to a different address does not show a problem at the hop
  ## address.
  if pool.dialsStopped or MixProtocolID notin protos:
    return false
  let hop = pool.nodePool.get(peerId).valueOr:
    return false
  return addrs == @[hop.multiAddr] and not pool.peerManager.switch.isConnected(peerId)

proc recordDialEvent(
    pool: MixPool,
    kind: DialEventKind,
    peerId: PeerId,
    addrs: seq[MultiAddress],
    protos: seq[string],
    error: string,
) =
  ## Records a failed or cancelled hop dial. A send cancels its first hop dial at
  ## `MixReplyTimeout`. A tcp dial to a host that ignores all packets has no
  ## result in that time. So the pool records the cancelled dial as a failed
  ## dial.
  if not pool.isHopDial(peerId, addrs, protos):
    return
  debug "Mix hop dial failed or cancelled", peerId = peerId, kind = kind, error = error
  pool.countFailureIfConnected(peerId)

proc clearExpiredFailures(pool: MixPool) =
  ## Puts each node back on paths `failureBackoff` after its recorded dial failure.
  let now = Moment.now()
  var due: seq[PeerId]
  for peerId, node in pool.known:
    if node.failedAt.isSome() and now - node.failedAt.get() >= pool.failureBackoff:
      due.add(peerId)
  for peerId in due:
    pool.known.withValue(peerId, node):
      node.failedAt = Opt.none(Moment)
    pool.refreshPeer(peerId)

proc removeExpiredNodes(pool: MixPool) =
  ## Removes each discovered node with no connection and a `lastSeen` older than
  ## `discoveredTtl`.
  let now = Moment.now()
  var old: seq[PeerId]
  for peerId, node in pool.known.mpairs():
    if node.source == MixNodeSource.Configured:
      continue
    if pool.peerManager.switch.isConnected(peerId):
      node.lastSeen = now
    elif now - node.lastSeen >= pool.discoveredTtl:
      old.add(peerId)
  for peerId in old:
    pool.known.del(peerId)
    trace "Mix peer removed, not seen within its time to live",
      peerId = peerId, discoveredTtl = $pool.discoveredTtl
    pool.refreshPeer(peerId)

proc maintain*(pool: MixPool) =
  ## One pass of the pool loop. Public for tests.
  pool.removeExpiredNodes()
  pool.clearExpiredFailures()

proc poolLoop(pool: MixPool) {.async: (raises: [CancelledError]).} =
  while true:
    pool.maintain()
    await sleepAsync(pool.poolLoopInterval)

proc start*(pool: MixPool) =
  ## Allows dials again and runs the pool loop.
  pool.dialsStopped = false
  if pool.loop.isNil() or pool.loop.finished():
    pool.loop = pool.poolLoop()

proc stop*(pool: MixPool) {.async: (raises: []).} =
  ## Cancels the pool loop and the dials, and sets `stopped` until `start`.
  pool.dialsStopped = true
  if not pool.loop.isNil():
    await pool.loop.cancelAndWait()
    pool.loop = nil
  await noCancel allFutures(toSeq(pool.dials.values()).mapIt(it.cancelAndWait()))
  pool.dials.clear()

proc new*(
    T: typedesc[MixPool], peerManager: PeerManager, policy: PeerAddressPolicy
): T =
  let members = PeerStore.new(nil)
  let pool = T(
    peerManager: peerManager,
    policy: policy,
    members: members,
    nodePool: MixNodePool.new(members),
  )
  pool.addBookHandlers()
  for peerId in toSeq(pool.store[MixPubKeyBook].book.keys()):
    pool.learn(peerId)
  # A `DeliveryDialer` tells the pool about each failed or cancelled stream dial.
  if peerManager.switch.dialer of DeliveryDialer:
    DeliveryDialer(peerManager.switch.dialer).dialEventHandlers.add(
      proc(
          kind: DialEventKind,
          peerId: PeerId,
          addrs: seq[MultiAddress],
          protos: seq[string],
          error: string,
      ) {.gcsafe, raises: [].} =
        pool.recordDialEvent(kind, peerId, addrs, protos, error)
    )
  return pool
