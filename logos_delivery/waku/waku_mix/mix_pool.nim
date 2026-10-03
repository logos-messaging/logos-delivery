## The mix pool. It follows the peer store of the node. A peer is a pool member
## when it has a mix key and a hop address that the policy accepts. A send dials
## pool peers through it.

{.push raises: [].}

import
  std/[sequtils, tables],
  chronicles,
  chronos,
  results,
  libp2p/crypto/curve25519,
  libp2p/crypto/crypto,
  libp2p_mix,
  libp2p_mix/mix_protocol,
  libp2p_mix/multiaddr as mix_multiaddr,
  libp2p/[multiaddress, peerid, peerinfo, peerstore, peeraddrpolicy, switch, wire]

import
  logos_delivery/waku/node/peer_manager,
  logos_delivery/waku/node/peer_manager/waku_peer_store

export peeraddrpolicy

logScope:
  topics = "waku mix pool"

type MixPool* = ref object
  peerManager: PeerManager
  policy: PeerAddressPolicy ## Accepts or rejects each hop address.
  known: MixNodePool ## Each peer with a mix key, in the peer store of the node.
  members: PeerStore ## One hop address for each pool member.
  nodePool: MixNodePool ## The pool over `members` that nim-libp2p-mix reads.
  dials: Table[PeerId, Future[bool].Raising([CancelledError])]
    ## The last dial of each peer. A later attempt joins it.
  dialsStopped: bool ## True from `stop` to `start`. Then no send starts a dial.

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
  ## The addresses of `peerId` that a hop can carry, the last dialed first.
  var candidates: seq[MultiAddress]
  let lastSeen = pool.store[LastSeenOutboundBook][peerId]
  if lastSeen.isSome():
    candidates.add(lastSeen.get().stripPeerId())
  candidates.add(pool.store[AddressBook][peerId])
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
  ## The pool entry for `peerId`. The peer needs a mix key, a secp256k1 key and a
  ## hop address. This node never gets an entry.
  let store = pool.store
  if peerId == pool.peerManager.switch.peerInfo.peerId:
    return Opt.none(MixPubInfo)
  let mixPubKey = store[MixPubKeyBook][peerId]
  if mixPubKey == default(Curve25519Key):
    return Opt.none(MixPubInfo)
  # `addPeer` and `MixNodePool.add` write the key book with each mix key.
  let pubKey = store[KeyBook][peerId]
  if pubKey.scheme != Secp256k1:
    return Opt.none(MixPubInfo)
  let address = pool.hopAddress(peerId).valueOr:
    return Opt.none(MixPubInfo)
  return Opt.some(MixPubInfo.init(peerId, address, mixPubKey, pubKey.skkey))

proc len*(pool: MixPool): int =
  ## The number of pool members.
  pool.members[MixPubKeyBook].len

func nodePool*(pool: MixPool): MixNodePool =
  ## The pool that nim-libp2p-mix draws paths from.
  pool.nodePool

proc refreshPeer(pool: MixPool, peerId: PeerId) =
  ## Makes the pool entry of `peerId` agree with the peer store of the node.
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

proc addBookHandlers(pool: MixPool) =
  ## Refreshes a peer when a book that decides its entry changes. The peer store
  ## cannot remove these handlers.
  let store = pool.store
  let onChange = proc(peerId: PeerId) {.gcsafe, raises: [].} =
    if peerId in store[MixPubKeyBook] or peerId in pool.members[MixPubKeyBook]:
      pool.refreshPeer(peerId)
  store[MixPubKeyBook].addHandler(onChange)
  store[AddressBook].addHandler(onChange)
  store[LastSeenOutboundBook].addHandler(onChange)
  store[KeyBook].addHandler(onChange)

proc addChangeHandler*(pool: MixPool, handler: PeerBookChangeHandler) =
  ## Calls `handler` when a peer joins or leaves the pool.
  pool.members[MixPubKeyBook].addHandler(handler)

proc add*(pool: MixPool, info: MixPubInfo) =
  ## Adds a configured mix node to the peer store.
  pool.known.add(info)

proc dialPeer(
    pool: MixPool, peerId: PeerId
): Future[bool] {.async: (raises: [CancelledError]).} =
  ## Dials `peerId` at its hop addresses. An existing connection counts as a
  ## success.
  let addresses = pool.hopAddresses(peerId)
  if addresses.len == 0:
    return false
  try:
    await pool.peerManager.switch.connect(peerId, addresses).wait(DefaultDialTimeout)
  except AsyncTimeoutError:
    debug "Mix peer dial timed out", peerId = peerId, addresses = $addresses
    return false
  except DialFailedError as exc:
    debug "Mix peer dial failed",
      peerId = peerId, addresses = $addresses, error = exc.msg
    return false
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

proc start*(pool: MixPool) =
  ## Allows dials again.
  pool.dialsStopped = false

proc stop*(pool: MixPool) {.async: (raises: []).} =
  ## Cancels the dials, and sets `stopped` until `start`.
  pool.dialsStopped = true
  await noCancel allFutures(toSeq(pool.dials.values()).mapIt(it.cancelAndWait()))
  pool.dials.clear()

proc new*(
    T: typedesc[MixPool], peerManager: PeerManager, policy: PeerAddressPolicy
): T =
  let members = PeerStore.new(nil)
  let pool = T(
    peerManager: peerManager,
    policy: policy,
    known: MixNodePool.new(peerManager.switch.peerStore),
    members: members,
    nodePool: MixNodePool.new(members),
  )
  pool.addBookHandlers()
  for peerId in pool.known.peerIds():
    pool.refreshPeer(peerId)
  return pool
