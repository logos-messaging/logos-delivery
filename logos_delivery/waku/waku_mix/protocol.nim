{.push raises: [].}

import std/[sequtils, strutils]
import chronicles, chronos, results, metrics

import
  libp2p/crypto/curve25519,
  libp2p/crypto/crypto,
  libp2p/crypto/rng,
  libp2p_mix,
  libp2p_mix/mix_node,
  libp2p_mix/mix_protocol,
  libp2p_mix/mix_metrics,
  libp2p_mix/multiaddr as mix_multiaddr,
  libp2p_mix/delay_strategy,
  libp2p_mix/serialization as mix_serialization,
  libp2p_mix/sphinx as mix_sphinx,
  libp2p/[multiaddress, peerid, switch],
  eth/common/keys

import
  logos_delivery/waku/node/peer_manager,
  logos_delivery/waku/waku_core,
  logos_delivery/waku/waku_enr,
  logos_delivery/waku/node/peer_manager/waku_peer_store,
  logos_delivery/waku/node/delivery_dialer,
  ./mix_pool,
  ./protocol_metrics

export mix_pool

logScope:
  topics = "waku mix"

const MinMixPoolSize* = 4
  ## The smallest pool that mix can build a path from. `PathLength` is 3, and
  ## with `exit_is_dest` the exit node is a pool member and not one of the hops.

const
  NoReplyHopError* = "no mix peer has a connection that can carry the reply"
    ## The last reply hop needs an existing connection to this node.
  MixReplyHopTimeout* = QuicDialTimeout + chronos.seconds(2)
    ## How long a send waits for the dials of `prepareReplyPath`. This is
    ## `QuicDialTimeout` for quic, then 2 seconds for tcp.
  MixReplyHopMaxDials = 2
    ## The maximum number of dials of one send. One pool peer that is down does
    ## not stop the send.
  MixStoppingError* = "mix is stopping" ## The error of a send after the pool stops.

type
  SelfHopSource* {.pure.} = enum
    ## The source of the self hop address.
    Observed ## Other peers observed the host, as discv5 and autonat do.
    Local ## An address of this machine, or a port mapping of its gateway.
    Configured ## The operator stated the address.

  WakuMix* = ref object of MixProtocol
    peerManager*: PeerManager
    clusterId: uint16
    pubKey*: Curve25519Key
    hopMissing: bool
      ## `true` when the last hop derivation found no address the encoder accepts.
      ## The hop that mix still holds is then a leftover, unusable even if it
      ## encodes.
    pool*: MixPool ## The mix pool. The `nodePool` of `MixProtocol` reads its members.
    delays: DelayStrategy ## The delay strategy of `MixProtocol.init`, for `buildSurb`.
    advertised*: bool ## True while this node advertises itself as a mix node.
    notAdvertisingReason*: string ## The last logged reason not to advertise.

  WakuMixResult*[T] = Result[T, string]

  MixNodePubInfo* = object
    multiAddr*: string
    pubKey*: Curve25519Key

const RoutableMixTransport = mapOr(
  TCP_IP4,
  QUIC_V1_IP4,
  mapAnd(DNS4, mapEq("tcp")),
  mapAnd(mapAnd(DNS4, mapEq("udp")), mapEq("quic-v1")),
)
  ## What `parseMixNode` accepts: the transports `MixNodePool.get` routes, and
  ## a `dns4` name for one of them. `parseMixNode` matches the base transport, as
  ## the pool does, so a circuit relay over one of them passes.

proc parseMixNode*(entry: string): Result[MixNodePubInfo, string] =
  ## Parses a `multiaddr:mixPublicKey` entry from `--mixnode` or a preset. It
  ## accepts a `dns4` name, which the node resolves after the mount, and refuses
  ## an address on a transport that the pool cannot route.
  # Split on the last colon: an address can hold colons (IPv6), a key cannot.
  let parts = entry.rsplit(':', maxsplit = 1)
  if parts.len != 2:
    return err("expected `multiaddr:mixPublicKey`, got: " & entry)

  discard MultiAddress.init(parts[0]).valueOr:
    return err("invalid multiaddress in mix node entry: " & parts[0])

  # `ncrutils.fromHex` ignores trailing junk, so check the exact shape first: a
  # mix key is 2*Curve25519KeySize hex characters.
  if parts[1].len != Curve25519KeySize * 2 or not parts[1].allCharsInSet(HexDigits):
    return err(
      "a mix public key is " & $(Curve25519KeySize * 2) & " hex characters, got: " &
        parts[1]
    )

  # `processBootNodes` needs a /p2p/<peer id>, so refuse an entry without one at
  # config. The message carries the parser's own reason.
  let pInfo = parsePeerInfo(parts[0]).valueOr:
    return err(
      "the peer address parser refused the mix node entry (" & error & "): " & parts[0]
    )

  # Require a transport the pool routes once the name is resolved; the peer
  # info parser also takes WebSocket, IPv6, dns6, dns and dnsaddr. Match the base
  # transport, as the pool does, so a relayed entry counts by the relay's address.
  let base = mix_multiaddr.getBaseTransport(pInfo.addrs[0]).valueOr:
    return err("mix cannot read the transport of the mix node entry: " & parts[0])
  if not RoutableMixTransport.match(base):
    return err(
      "mix routes IPv4 TCP or QUIC-v1 only, directly or through a circuit relay (a dns4 name is resolved after the mount), got: " &
        parts[0]
    )

  return ok(
    MixNodePubInfo(
      multiAddr: parts[0], pubKey: intoCurve25519Key(ncrutils.fromHex(parts[1]))
    )
  )

proc poolSize*(mix: WakuMix): int =
  ## The number of pool members.
  mix.pool.len

proc updatePoolSize*(size: int) =
  ## Sets `mix_pool_size`. This is its only writer. The mount, `addBootNodes`
  ## and each health pass publish the count that they read.
  mix_pool_size.set(size)

proc replyHops(mix: WakuMix, excluded: openArray[PeerId]): seq[MixPubInfo] =
  ## The pool entries that a reply path can use, except `excluded`.
  var hops: seq[MixPubInfo]
  for peerId in mix.nodePool.peerIds():
    if peerId in excluded:
      continue
    let hop = mix.nodePool.get(peerId).valueOr:
      continue
    hops.add(hop)
  return hops

proc connected(mix: WakuMix, hop: MixPubInfo): bool =
  ## True when `hop` has a connection to this node, which can carry a reply.
  mix.switch.isConnected(hop.peerId)

proc replyPath*(
    mix: WakuMix, destPeerId: PeerId, exitPeerId: PeerId
): Result[seq[MixPubInfo], string] =
  ## Returns the reply path, which ends at this node. The hop before this node is
  ## a pool peer with a connection to this node. The other hops are random.
  ## Public for tests.
  let local = mix.localMixPubInfo()
  let candidates = mix.replyHops([local.peerId, destPeerId, exitPeerId])
  if candidates.len < PathLength - 1:
    return err(
      "not enough mix peers for a reply path: " & $candidates.len & " of " &
        $(PathLength - 1)
    )

  let last = mix.switch.rng.pickOne(candidates.filterIt(mix.connected(it))).valueOr:
    return err(NoReplyHopError)
  let others = candidates.filterIt(it.peerId != last.peerId)
  let preceding = mix.switch.rng.pick(others, PathLength - 2).valueOr:
    return err("not enough mix peers for a reply path")
  let path = preceding & @[last, local]
  debug "Mix reply path selected",
    hops = path.mapIt(shortLog(it.peerId)), addresses = path.mapIt($it.multiAddr)
  return ok(path)

method buildSurb*(
    mix: WakuMix, id: SURBIdentifier, destPeerId: PeerId, exitPeerId: PeerId
): Result[SURB, string] {.gcsafe, raises: [].} =
  ## Builds the SURB on `replyPath`, with the delay strategy of the forward path.
  let path = ?mix.replyPath(destPeerId, exitPeerId)

  var
    keys: seq[Curve25519Key]
    hops: seq[Hop]
    delays: seq[Delay]
  for i, hop in path:
    let encoded = mix_multiaddr.multiAddrToBytes(hop.peerId, hop.multiAddr).valueOr:
      mix_messages_error.inc(labelValues = ["Entry/SURB", "INVALID_MIX_INFO"])
      return err("failed to convert multiaddress to bytes: " & error)
    keys.add(hop.mixPubKey)
    hops.add(Hop.init(encoded))
    # The last hop is this node. It adds no delay.
    delays.add(
      if i < path.len - 1:
        mix.delays.generateForEntry()
      else:
        NoDelay
    )

  return createSURB(keys, delays, hops, id, mix.switch.rng)

proc dialReplyHop(
    mix: WakuMix, candidates: seq[MixPubInfo]
): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
  ## Dials up to `MixReplyHopMaxDials` of `candidates`, which have no connection.
  ## Returns at the first success or at `MixReplyHopTimeout`. The dials continue
  ## after the return, because a cancel could close a connection that
  ## `buildSurb` chose.
  let chosen = mix.switch.rng.pick(candidates, MixReplyHopMaxDials).valueOr:
    return err(NoReplyHopError & ", and the pool has no peer to dial")
  var pending = chosen.mapIt(mix.pool.dial(it.peerId))
  let deadline = sleepAsync(MixReplyHopTimeout)
  try:
    while pending.len > 0 and not deadline.finished():
      try:
        discard await race(pending.mapIt(FutureBase(it)) & @[FutureBase(deadline)])
      except ValueError:
        break
      if pending.anyIt(it.completed() and it.value()):
        return ok()
      pending.keepItIf(not it.finished())
  finally:
    await deadline.cancelAndWait()
  if pending.len > 0:
    return err(
      NoReplyHopError & ", and no dial to a pool peer answered within " &
        $MixReplyHopTimeout
    )
  return err(NoReplyHopError & ", and " & $chosen.len & " dials to pool peers failed")

proc prepareReplyPath*(
    mix: WakuMix, exitPeerId: PeerId
): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
  ## Makes sure that a pool peer other than the exit has a connection to this
  ## node, so that `buildSurb` has a last reply hop. Public for tests.
  if mix.pool.stopped():
    return err(MixStoppingError)
  let candidates = mix.replyHops([mix.switch.peerInfo.peerId, exitPeerId])
  if candidates.anyIt(mix.connected(it)):
    return ok()
  let attempt = await mix.dialReplyHop(candidates)
  if attempt.isErr():
    logos_delivery_mix_reply_hop_failures.inc()
    return attempt
  debug "Mix reply hop ready"
  return ok()

when defined(libp2p_mix_experimental_exit_is_dest):
  proc exitConnection*(
      mix: WakuMix, exitPeerId: PeerId, codec: string, params: MixParameters
  ): Future[Result[Connection, string]] {.async: (raises: [CancelledError]).} =
    ## Returns a mix connection to the exit `exitPeerId`. Prepares the reply path
    ## when `params` expects a reply.
    if params.expectReply.get(false):
      ?(await mix.prepareReplyPath(exitPeerId))
    return mix.toConnection(MixDestination.exitNode(exitPeerId), codec, params)

method start*(mix: WakuMix) {.async: (raises: [CancelledError]).} =
  await procCall MixProtocol(mix).start()
  mix.pool.start()

method stop*(mix: WakuMix) {.async: (raises: []).} =
  await mix.pool.stop()
  await procCall MixProtocol(mix).stop()

proc processBootNodes(
    bootnodes: seq[MixNodePubInfo], peermgr: PeerManager, mix: WakuMix
) =
  var count = 0
  var refused: seq[string]
  for node in bootnodes:
    let pInfo = parsePeerInfo(node.multiAddr).valueOr:
      error "Failed to get peer id from multiaddress: ",
        error = error, multiAddr = $node.multiAddr
      continue
    let peerId = pInfo.peerId

    # A fleet node finds itself in its own preset. Skip that entry, or mix could
    # draw this node as a hop or an exit and route a packet to itself.
    if peerId == peermgr.switch.peerInfo.peerId:
      debug "Skipping a mix bootstrap node that is this node itself", peerId = peerId
      continue

    var peerPubKey: crypto.PublicKey
    if not peerId.extractPublicKey(peerPubKey):
      warn "Failed to extract public key from peerId, skipping node", peerId = peerId
      continue

    if peerPubKey.scheme != PKScheme.Secp256k1:
      warn "Peer public key is not Secp256k1, skipping node",
        peerId = peerId, scheme = peerPubKey.scheme
      continue

    # The wire address, without the `/p2p/<id>` part. Mix compares pool
    # addresses with its transport patterns, and the suffix stops the match.
    let multiAddr = pInfo.addrs[0]

    # `add` comes before `addPeer`. `add` writes a new address with `Infinite`
    # confidence, and `addPeer` does not lower that confidence.
    mix.pool.add(MixPubInfo.init(peerId, multiAddr, node.pubKey, peerPubKey.skkey))
    count.inc()
    if not mix.pool.accepts(multiAddr):
      refused.add(node.multiAddr)

    peermgr.addPeer(
      RemotePeerInfo.init(
        peerId, @[multiAddr], publicKey = peerPubKey, mixPubKey = Opt.some(node.pubKey)
      )
    )
  if refused.len > 0:
    warn "Configured mix nodes have no public direct address and are not on " &
      "mix paths. Set --mix-allow-all-addresses=true for a local simulation, a " &
      "test or a private network",
      refused = refused.len, examples = refused[0 ..< min(refused.len, 3)]
  # `count` is the accepted entries; the addresses of one peer make one member.
  info "Using mix bootstrap nodes", entries = count, poolSize = mix.poolSize()

proc addBootNodes*(mix: WakuMix, bootnodes: seq[MixNodePubInfo]) =
  ## Adds bootstrap nodes resolved after the mount, and publishes the pool size.
  processBootNodes(bootnodes, mix.peerManager, mix)
  updatePoolSize(mix.poolSize())

proc new*(
    T: typedesc[WakuMix],
    nodeAddr: string,
    peermgr: PeerManager,
    clusterId: uint16,
    mixPrivKey: Curve25519Key,
    bootnodes: seq[MixNodePubInfo],
    addressPolicy: PeerAddressPolicy,
): WakuMixResult[T] =
  let mixPubKey = public(mixPrivKey)
  info "mixPubKey", mixPubKey = mixPubKey
  let nodeMultiAddr = MultiAddress.init(nodeAddr).valueOr:
    return err("failed to parse mix node address: " & $nodeAddr & ", error: " & error)
  let localMixNodeInfo = initMixNodeInfo(
    peermgr.switch.peerInfo.peerId, nodeMultiAddr, mixPubKey, mixPrivKey,
    peermgr.switch.peerInfo.publicKey.skkey, peermgr.switch.peerInfo.privateKey.skkey,
  )

  let delays = DelayStrategy(
    ExponentialDelayStrategy.new(meanDelay = 50'u16, rng = crypto.newRng())
  )
  let m = WakuMix(
    peerManager: peermgr,
    clusterId: clusterId,
    pubKey: mixPubKey,
    pool: MixPool.new(peermgr, addressPolicy),
    delays: delays,
  )
  procCall MixProtocol(m).init(
    localMixNodeInfo, peermgr.switch, delayStrategy = Opt.some(delays)
  )
  # `init` sets `nodePool` to the peer store of the switch. Paths must use only
  # the pool members.
  m.nodePool = m.pool.nodePool
  processBootNodes(bootnodes, peermgr, m)

  let usable = m.poolSize()
  updatePoolSize(usable)

  if usable < MinMixPoolSize:
    info "Mix cannot publish yet, waiting for more mix nodes",
      poolSize = usable, required = MinMixPoolSize
  return ok(m)

proc selfHopMissing*(mix: WakuMix): bool =
  ## True when the last derivation of this node's own hop found nothing to set.
  mix.hopMissing

proc selfHopUsable*(mix: WakuMix): bool =
  ## True when the encoder accepts this node's own hop (IPv4 TCP or QUIC-v1, or
  ## a circuit relay over one) and `hopMissing` is not set. Every reply path and
  ## cover packet fails at build time on a hop that the encoder rejects.
  if mix.hopMissing:
    return false
  let info = mix.localMixPubInfo()
  return mix_multiaddr.multiAddrToBytes(info.peerId, info.multiAddr).isOk()

proc selfHopAllowed*(mix: WakuMix): bool =
  ## True when the encoder and the address policy accept the self hop.
  return mix.selfHopUsable() and mix.pool.accepts(mix.localMixPubInfo().multiAddr)

proc updateSelfHop*(
    mix: WakuMix, preferred: seq[MultiAddress], fallback: seq[MultiAddress]
): Opt[MultiAddress] =
  ## Sets this node's own hop to the first candidate in `preferred`, then in
  ## `fallback`, that the library accepts, and returns it. When none encodes,
  ## the hop stays as it was, `hopMissing` is set, and the result is none.
  for candidate in preferred & fallback:
    if mix.setLocalMultiAddr(candidate).isOk():
      mix.hopMissing = false
      return Opt.some(candidate)
  mix.hopMissing = true
  return Opt.none(MultiAddress)

# Mix Protocol
