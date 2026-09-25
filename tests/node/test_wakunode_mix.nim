{.used.}

import std/[sequtils, strutils]
import testutils/unittests, chronos, results, metrics
import libp2p/[crypto/crypto, peerid, multiaddress]
import libp2p/nameresolving/nameresolver
import libp2p_mix, libp2p_mix/[curve25519, mix_metrics]

import
  logos_delivery/waku/[
    waku_core,
    common/waku_protocol,
    net/net_config,
    node/enr_addresses,
    node/peer_manager,
    node/waku_node,
    node/health_monitor/health_status,
    node/health_monitor/protocol_health,
    node/health_monitor/node_health_monitor,
    waku_mix,
    waku_mix/protocol_metrics,
  ],
  ../testlib/[wakucore, wakunode, testasync]

## Mix's own hop closes every reply path this node asks for. On every address
## commit the node sets it to the first address mix can encode: a direct address
## known from outside, the ENR endpoint, a relay route, then the resolved set.

proc selfHop(node: WakuNode): MultiAddress =
  node.wakuMix.localMixPubInfo().multiAddr

proc boundTcpPort(node: WakuNode): Port =
  getPorts(node.switch.peerInfo.listenAddrs).expect("bound ports").tcpPort.get()

proc mountTestMix(node: WakuNode) {.async.} =
  let mixKeys = generateKeyPair().expect("mix key pair")
  (await node.mountMix(DefaultClusterId, mixKeys.privateKey, @[])).isOkOr:
    raiseAssert "Failed to mount mix: " & $error

proc mixHealth(node: WakuNode): ProtocolHealth =
  NodeHealthMonitor.new(node).getSyncProtocolHealthInfo(WakuProtocol.MixProtocol)

suite "Waku Mix - the node's own hop":
  asyncTest "the hop follows the bound port once the node starts":
    ## The mount takes port 0; `start()` binds the real port, and the hop must
    ## follow it.
    let node =
      newTestWakuNode(generateSecp256k1Key(), parseIpAddress("127.0.0.1"), Port(0))
    await node.mountTestMix()
    check $node.selfHop() == "/ip4/127.0.0.1/tcp/0"

    await node.start()
    check:
      node.selfHop() == node.announcedAddresses[0]
      $node.selfHop() != "/ip4/127.0.0.1/tcp/0"
      node.wakuMix.selfHopUsable()
    await node.stop()

  asyncTest "the default deployment takes the primary interface, not the wildcard":
    ## A wildcard bind with nothing configured leaves only the resolved set, so
    ## the hop is its resolved host, which replaces the mount's `0.0.0.0`.
    let node = newTestWakuNode(
      generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0), quicEnabled = false
    )
    await node.mountTestMix()
    check $node.selfHop() == "/ip4/0.0.0.0/tcp/0"

    await node.start()
    check:
      node.enrAddresses().len == 0
      node.selfHop() == node.announcedAddresses[0]
      "0.0.0.0" notin $node.selfHop()
      node.wakuMix.selfHopUsable()
    await node.stop()

  asyncTest "an address known from outside outranks the primary interface":
    ## Peers learn the operator-configured address, so it outranks the primary
    ## interface that a wildcard bind resolves to.
    let outside = MultiAddress.init("/ip4/203.0.113.9/tcp/60000").tryGet()
    let node = newTestWakuNode(
      generateSecp256k1Key(),
      parseIpAddress("0.0.0.0"),
      Port(0),
      extMultiAddrs = @[outside],
      quicEnabled = false,
    )
    await node.mountTestMix()
    check $node.selfHop() == "/ip4/0.0.0.0/tcp/0"

    await node.start()
    check:
      node.enrAddresses() == @[outside]
      node.announcedAddresses.len == 2
      node.selfHop() == outside
    await node.stop()

  asyncTest "an explicit bind host stays first, as in the ENR":
    ## A concrete `--listen-address` is announced ahead of an `--ext-multiaddr`.
    ## The hop follows the order of the ENR scalars, so both name one endpoint.
    let outside = MultiAddress.init("/ip4/203.0.113.9/tcp/60000").tryGet()
    let node = newTestWakuNode(
      generateSecp256k1Key(),
      parseIpAddress("127.0.0.1"),
      Port(0),
      extMultiAddrs = @[outside],
      quicEnabled = false,
    )
    await node.mountTestMix()
    await node.start()
    check:
      node.enrAddresses().len == 2
      node.selfHop() == node.announcedAddresses[0]
      $node.selfHop() == "/ip4/127.0.0.1/tcp/" & $node.boundTcpPort()
    await node.stop()

  asyncTest "a direct operator address outranks a relay route":
    ## The autorelay mapper announces a circuit route first. Only a relay client
    ## can dial it and the ENR scalars never carry it, so a direct address wins.
    let relayId = PeerId.init(generateSecp256k1Key()).tryGet()
    let circuit = MultiAddress
      .init("/ip4/203.0.113.1/tcp/60000/p2p/" & $relayId & "/p2p-circuit")
      .tryGet()
    let direct = MultiAddress.init("/ip4/203.0.113.5/tcp/60001").tryGet()
    let node = newTestWakuNode(
      generateSecp256k1Key(),
      parseIpAddress("127.0.0.1"),
      Port(0),
      extMultiAddrs = @[circuit, direct],
      extMultiAddrsOnly = true,
      quicEnabled = false,
    )
    await node.mountTestMix()
    check node.selfHop() == circuit # the mount takes the first announced address

    await node.start()
    check:
      node.announcedAddresses == @[circuit, direct]
      node.selfHop() == direct
    await node.stop()

  asyncTest "a node announcing a name takes the host the name resolved to":
    ## A fleet node announces a name, which mix cannot encode. The hop is the
    ## ENR endpoint: the external IP that the factory resolved the name to.
    let node = newTestWakuNode(
      generateSecp256k1Key(),
      parseIpAddress("0.0.0.0"),
      Port(0),
      extIp = Opt.some(parseIpAddress("203.0.113.9")),
      extPort = Opt.some(Port(30303)),
      dns4DomainName = Opt.some("node.test"),
      quicEnabled = false,
    )
    await node.mountTestMix()
    check:
      $node.selfHop() == "/dns4/node.test/tcp/30303"
      not node.wakuMix.selfHopUsable()

    await node.start()
    check:
      node.announcedAddresses.allIt("/dns4/" in $it)
      $node.selfHop() == "/ip4/203.0.113.9/tcp/30303"
      node.wakuMix.selfHopUsable()
    await node.stop()

  asyncTest "the host a name resolved to outranks a relay route":
    ## A fleet node with a relay route: the hop is the resolved host, as in the
    ## ENR, and the relay route comes after every direct endpoint.
    let relayId = PeerId.init(generateSecp256k1Key()).tryGet()
    let circuit = MultiAddress
      .init("/ip4/203.0.113.1/tcp/60000/p2p/" & $relayId & "/p2p-circuit")
      .tryGet()
    let node = newTestWakuNode(
      generateSecp256k1Key(),
      parseIpAddress("0.0.0.0"),
      Port(0),
      extIp = Opt.some(parseIpAddress("203.0.113.9")),
      extPort = Opt.some(Port(30303)),
      extMultiAddrs = @[circuit],
      dns4DomainName = Opt.some("node.test"),
      quicEnabled = false,
    )
    await node.mountTestMix()
    await node.start()
    check:
      node.announcedAddresses ==
        @[MultiAddress.init("/dns4/node.test/tcp/30303").tryGet(), circuit]
      node.enrAddresses().len == 2
      $node.selfHop() == "/ip4/203.0.113.9/tcp/30303"
    await node.stop()

  asyncTest "an operator address outranks the host a name resolved to":
    let outside = MultiAddress.init("/ip4/198.51.100.7/tcp/60001").tryGet()
    let node = newTestWakuNode(
      generateSecp256k1Key(),
      parseIpAddress("0.0.0.0"),
      Port(0),
      extIp = Opt.some(parseIpAddress("203.0.113.9")),
      extPort = Opt.some(Port(30303)),
      extMultiAddrs = @[outside],
      dns4DomainName = Opt.some("node.test"),
      quicEnabled = false,
    )
    await node.mountTestMix()
    await node.start()
    check node.selfHop() == outside
    await node.stop()

  asyncTest "a name resolved again at start moves the hop with the ENR host":
    ## `Waku.start` resolves a dns4 name again and hands the result to the ENR
    ## scalars. The hop follows, so the record and the reply path name one host.
    let node = newTestWakuNode(
      generateSecp256k1Key(),
      parseIpAddress("0.0.0.0"),
      Port(0),
      extIp = Opt.some(parseIpAddress("203.0.113.9")),
      extPort = Opt.some(Port(30303)),
      dns4DomainName = Opt.some("node.test"),
      quicEnabled = false,
    )
    await node.mountTestMix()
    await node.start()
    check $node.selfHop() == "/ip4/203.0.113.9/tcp/30303"

    let resolvedAgain = NetConfig
      .init(
        bindIp = parseIpAddress("0.0.0.0"),
        bindPort = Port(0),
        extIp = Opt.some(parseIpAddress("198.51.100.7")),
        extPort = Opt.some(Port(30303)),
        dns4DomainName = Opt.some("node.test"),
      )
      .expect("NetConfig")
    node.updateEnrConfiguredEndpoint(resolvedAgain)
    check $node.selfHop() == "/ip4/198.51.100.7/tcp/30303"
    await node.stop()

  asyncTest "a host discv5 confirmed outranks the primary interface":
    ## A host that discv5 confirmed is known from outside; a commit after start
    ## gives it to mix.
    let node = newTestWakuNode(
      generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0), quicEnabled = false
    )
    await node.mountTestMix()
    await node.start()
    check "0.0.0.0" notin $node.selfHop()

    node.enrLearnedEndpoint =
      Opt.some(DiscoveryEndpoint((ip: parseIpAddress("203.0.113.9"), udp: Port(9000))))
    node.copyCommittedAddresses()
    check $node.selfHop() == "/ip4/203.0.113.9/tcp/" & $node.boundTcpPort()
    await node.stop()

  asyncTest "a node with no address mix can encode starts, and mix says so":
    ## A name and nothing else on a wildcard bind. The node starts, keeps the
    ## mount's hop, and mix health reports not ready with the reason.
    let node = newTestWakuNode(
      generateSecp256k1Key(),
      parseIpAddress("0.0.0.0"),
      Port(0),
      extPort = Opt.some(Port(30303)),
      dns4DomainName = Opt.some("node.test"),
      quicEnabled = false,
    )
    await node.mountTestMix()
    await node.start()

    let health = node.mixHealth()
    check:
      node.started
      $node.selfHop() == "/dns4/node.test/tcp/30303"
      node.wakuMix.selfHopMissing()
      not node.wakuMix.selfHopUsable()
      health.health == HealthStatus.NOT_READY
      "replies" in health.desc.get("")
    await node.stop()

  asyncTest "a derivation that finds nothing marks a leftover unusable even if it encodes":
    ## The mount's hop can encode and still be a placeholder. After a derivation
    ## that finds nothing it is unusable, until a derivation finds a hop.
    let node =
      newTestWakuNode(generateSecp256k1Key(), parseIpAddress("127.0.0.1"), Port(0))
    await node.mountTestMix()
    let name = MultiAddress.init("/dns4/node.test/tcp/30303").tryGet()
    check node.wakuMix.selfHopUsable() # the mount-time hop encodes

    check:
      node.wakuMix.updateSelfHop(@[name], @[name]).isNone()
      $node.selfHop() == "/ip4/127.0.0.1/tcp/0" # left as it was
      node.wakuMix.selfHopMissing()
      not node.wakuMix.selfHopUsable()

    let direct = MultiAddress.init("/ip4/127.0.0.1/tcp/60000").tryGet()
    check:
      node.wakuMix.updateSelfHop(@[name], @[direct]) == Opt.some(direct)
      not node.wakuMix.selfHopMissing()
      node.wakuMix.selfHopUsable()
    await node.stop()

  asyncTest "a restart re-derives the hop":
    ## `stop()` clears the resolved base, and the commit in the next `start()`
    ## replaces a hop that went stale in between.
    let node =
      newTestWakuNode(generateSecp256k1Key(), parseIpAddress("127.0.0.1"), Port(0))
    await node.mountTestMix()
    await node.start()
    check node.selfHop() == node.announcedAddresses[0]
    await node.stop()

    let stale = MultiAddress.init("/ip4/127.0.0.1/tcp/1").tryGet()
    node.wakuMix.setLocalMultiAddr(stale).expect("an IPv4 TCP hop")
    await node.start()
    check:
      node.selfHop() != stale
      node.selfHop() == node.announcedAddresses[0]
      node.wakuMix.selfHopUsable()
    await node.stop()

## `poolSize` counts the live pool members a path can use; `mixReady` and the
## `mix_pool_size` gauge read it. The cases that read the gauge publish it first
## with `updatePoolSize`, as the mount and the health pass do.

suite "Waku Mix - pool size":
  var node {.threadvar.}: WakuNode

  asyncSetup:
    node = newTestWakuNode(generateSecp256k1Key())

    # Mount before start, as the node factory does: a switch that runs cannot
    # mount a new protocol.
    let mixKeys = generateKeyPair().expect("mix key pair")
    (await node.mountMix(DefaultClusterId, mixKeys.privateKey, @[])).isOkOr:
      raiseAssert "Failed to mount mix: " & $error

    await node.start()

  asyncTeardown:
    await node.stop()

  proc addMixPeer(address: string): PeerId =
    ## Stores a mix key and its address in the peer store, as discovery does.
    ## The pool reads the peer store.
    let peerId = PeerId.init(generateSecp256k1Key()).tryGet()
    let mixKeys = generateKeyPair().expect("mix key pair")
    node.peerManager.addPeer(
      RemotePeerInfo.init(
        peerId,
        @[MultiAddress.init(address).tryGet()],
        mixPubKey = Opt.some(mixKeys.publicKey),
      )
    )
    return peerId

  asyncTest "a node with no mix peers has an empty pool":
    check node.getMixNodePoolSize() == 0

  asyncTest "only the peers mix can route count towards the pool":
    ## Mix routes IPv4 TCP and QUIC-v1. The `dns4` and `ip6` peers have a mix key
    ## and no address that a path can use.
    discard addMixPeer("/ip4/127.0.0.1/tcp/60001")
    discard addMixPeer("/ip4/127.0.0.1/udp/60002/quic-v1")
    discard addMixPeer("/dns4/node.test/tcp/60003")
    discard addMixPeer("/ip6/::1/tcp/60004")

    updatePoolSize(node.getMixNodePoolSize())
    check:
      node.getMixNodePoolSize() == 2
      mix_pool_size.value() == 2.0

  asyncTest "the pool follows the peers discovery brings in":
    ## The count is the live pool, so it grows as mix keys arrive.
    check node.getMixNodePoolSize() == 0

    for port in 60010 .. 60012:
      discard addMixPeer("/ip4/127.0.0.1/tcp/" & $port)
    check node.getMixNodePoolSize() == 3

    discard addMixPeer("/ip4/127.0.0.1/tcp/60013")
    updatePoolSize(node.getMixNodePoolSize())
    check:
      node.getMixNodePoolSize() == 4
      mix_pool_size.value() == 4.0

  asyncTest "mix is not ready until enough peers can carry a packet":
    ## `mixReady` needs `poolSize() >= MinMixPoolSize`, so an unroutable peer
    ## must not count toward it.
    for port in 60020 .. 60022:
      discard addMixPeer("/ip4/127.0.0.1/tcp/" & $port)
    discard addMixPeer("/dns4/node.test/tcp/60023")

    check node.getMixNodePoolSize() == 3 # the `dns4` peer does not count

    discard addMixPeer("/ip4/127.0.0.1/tcp/60024")
    check node.getMixNodePoolSize() == MinMixPoolSize

  asyncTest "the gauge at mount counts routable bootnodes, not parsed ones":
    ## An IPv6 bootnode parses at mount and mix cannot route it. The gauge and
    ## the pool size count only the routable bootnode.
    proc bootnode(address: string): MixNodePubInfo =
      let peerId = PeerId.init(generateSecp256k1Key()).tryGet()
      let keys = generateKeyPair().expect("mix key pair")
      return
        MixNodePubInfo(multiAddr: address & "/p2p/" & $peerId, pubKey: keys.publicKey)

    let other = newTestWakuNode(generateSecp256k1Key())
    let mixKeys = generateKeyPair().expect("mix key pair")
    (
      await other.mountMix(
        DefaultClusterId,
        mixKeys.privateKey,
        @[bootnode("/ip4/127.0.0.1/tcp/60030"), bootnode("/ip6/::1/tcp/60031")],
      )
    ).isOkOr:
      raiseAssert "Failed to mount mix: " & $error
    await other.start()

    check:
      other.getMixNodePoolSize() == 1
      mix_pool_size.value() == 1.0

    await other.stop()

suite "Waku Mix - pool size without mix":
  asyncTest "a node that never mounted mix reports an empty pool":
    let node = newTestWakuNode(generateSecp256k1Key())
    check node.getMixNodePoolSize() == 0

type StubResolver = ref object of NameResolver ## Answers every name with one address.
  answer: string

method resolveTxt(
    self: StubResolver, address: string
): Future[seq[string]] {.async: (raises: [CancelledError]).} =
  return @[]

method resolveIp(
    self: StubResolver, address: string, port: Port, domain: Domain = Domain.AF_UNSPEC
): Future[seq[TransportAddress]] {.
    async: (raises: [CancelledError, TransportAddressError])
.} =
  return @[initTAddress(self.answer, port)]

proc mixBootnode(address: string): MixNodePubInfo =
  ## A bootstrap entry as a preset ships it: an address with a peer id, and the
  ## node's mix public key.
  let peerId = PeerId.init(generateSecp256k1Key()).tryGet()
  let mixKeys = generateKeyPair().expect("mix key pair")
  return
    MixNodePubInfo(multiAddr: address & "/p2p/" & $peerId, pubKey: mixKeys.publicKey)

type EmptyResolver = ref object of NameResolver
  ## Answers with no address, as `DnsResolver` does for a name with no record or
  ## no reachable server.

method resolveTxt(
    self: EmptyResolver, address: string
): Future[seq[string]] {.async: (raises: [CancelledError]).} =
  return @[]

method resolveIp(
    self: EmptyResolver, address: string, port: Port, domain: Domain = Domain.AF_UNSPEC
): Future[seq[TransportAddress]] {.
    async: (raises: [CancelledError, TransportAddressError])
.} =
  return @[]

type RaisingResolver = ref object of NameResolver

method resolveTxt(
    self: RaisingResolver, address: string
): Future[seq[string]] {.async: (raises: [CancelledError]).} =
  return @[]

method resolveIp(
    self: RaisingResolver,
    address: string,
    port: Port,
    domain: Domain = Domain.AF_UNSPEC,
): Future[seq[TransportAddress]] {.
    async: (raises: [CancelledError, TransportAddressError])
.} =
  raise newException(TransportAddressError, "scripted resolver failure")

type TwoAddressResolver = ref object of NameResolver ## A name with two A records.

method resolveTxt(
    self: TwoAddressResolver, address: string
): Future[seq[string]] {.async: (raises: [CancelledError]).} =
  return @[]

method resolveIp(
    self: TwoAddressResolver,
    address: string,
    port: Port,
    domain: Domain = Domain.AF_UNSPEC,
): Future[seq[TransportAddress]] {.
    async: (raises: [CancelledError, TransportAddressError])
.} =
  return @[initTAddress("127.0.0.1", port), initTAddress("127.0.0.2", port)]

suite "Waku Mix - bootstrap nodes":
  ## Presets pin `dns4` names. The mount seeds the pool with the literal entries
  ## and resolves the names in the background: mix routes literal addresses only.

  proc mountWith(
      bootnodes: seq[MixNodePubInfo], nameResolver: NameResolver = nil
  ): Future[WakuNode] {.async.} =
    let node = newTestWakuNode(generateSecp256k1Key(), nameResolver = nameResolver)
    let mixKeys = generateKeyPair().expect("mix key pair")
    (await node.mountMix(DefaultClusterId, mixKeys.privateKey, bootnodes)).isOkOr:
      raiseAssert "Failed to mount mix: " & $error
    await node.start()
    await node.mixNodesResolved()
    return node

  asyncTest "literal addresses seed the pool at mount":
    ## A seeded pool can build a path before discovery runs.
    let node = await mountWith(
      @[
        mixBootnode("/ip4/127.0.0.1/tcp/60101"),
        mixBootnode("/ip4/127.0.0.1/tcp/60102"),
        mixBootnode("/ip4/127.0.0.1/tcp/60103"),
        mixBootnode("/ip4/127.0.0.1/tcp/60104"),
      ]
    )

    check node.getMixNodePoolSize() == MinMixPoolSize
    await node.stop()

  asyncTest "a node skips its own entry in the bootstrap list":
    ## A fleet node finds itself in its own preset. The mount skips that entry,
    ## so mix never draws this node as a hop or an exit.
    let node = newTestWakuNode(generateSecp256k1Key())
    let selfKeys = generateKeyPair().expect("mix key pair")
    let selfEntry = MixNodePubInfo(
      multiAddr: "/ip4/127.0.0.1/tcp/60105/p2p/" & $node.switch.peerInfo.peerId,
      pubKey: selfKeys.publicKey,
    )
    let mixKeys = generateKeyPair().expect("mix key pair")
    (
      await node.mountMix(
        DefaultClusterId,
        mixKeys.privateKey,
        @[selfEntry, mixBootnode("/ip4/127.0.0.1/tcp/60106")],
      )
    ).isOkOr:
      raiseAssert "Failed to mount mix: " & $error
    await node.start()

    check:
      node.getMixNodePoolSize() == 1
      node.switch.peerInfo.peerId notin node.wakuMix.nodePool.peerIds()
    await node.stop()

  asyncTest "a name the node cannot resolve is dropped, and the rest still mount":
    ## `newTestWakuNode` has no name resolver, so the mount drops both names and
    ## keeps the literals. The pool counts only routable members, so the counter
    ## is the witness of the drop.
    let droppedBefore = logos_delivery_mix_bootnode_resolve_failures.value()
    let node = await mountWith(
      @[
        mixBootnode("/ip4/127.0.0.1/tcp/60111"),
        mixBootnode("/dns4/delivery-01.example.invalid/tcp/30303"),
        mixBootnode("/ip4/127.0.0.1/tcp/60112"),
        mixBootnode("/dns4/delivery-02.example.invalid/tcp/30303"),
      ]
    )

    check:
      node.getMixNodePoolSize() == 2
      logos_delivery_mix_bootnode_resolve_failures.value() - droppedBefore == 2.0
    await node.stop()

  asyncTest "a name is resolved into the address mix routes":
    ## A preset pins `/dns4/<host>/tcp/30303`, and the pool holds the literal
    ## address that the name resolves to.
    let node = await mountWith(
      @[
        mixBootnode("/dns4/delivery-01.example.invalid/tcp/30301"),
        mixBootnode("/dns4/delivery-02.example.invalid/tcp/30302"),
        mixBootnode("/dns4/delivery-03.example.invalid/tcp/30303"),
        mixBootnode("/dns4/delivery-04.example.invalid/tcp/30304"),
      ],
      StubResolver(answer: "127.0.0.1"),
    )

    check node.getMixNodePoolSize() == MinMixPoolSize
    await node.stop()

  asyncTest "a name that answers with no address is dropped, the rest still mount":
    ## `DnsResolver` answers a dead or stale name with an empty list. The counter
    ## is the witness of the drop.
    let droppedBefore = logos_delivery_mix_bootnode_resolve_failures.value()
    let node = await mountWith(
      @[
        mixBootnode("/ip4/127.0.0.1/tcp/60121"),
        mixBootnode("/dns4/gone-01.example.invalid/tcp/30303"),
        mixBootnode("/ip4/127.0.0.1/tcp/60122"),
        mixBootnode("/dns4/gone-02.example.invalid/tcp/30303"),
      ],
      EmptyResolver(),
    )

    check:
      node.getMixNodePoolSize() == 2
      logos_delivery_mix_bootnode_resolve_failures.value() - droppedBefore == 2.0
    await node.stop()

  asyncTest "a lookup that raises is dropped, the rest still mount":
    ## As above, the counter is the witness of the drop.
    let droppedBefore = logos_delivery_mix_bootnode_resolve_failures.value()
    let node = await mountWith(
      @[
        mixBootnode("/ip4/127.0.0.1/tcp/60131"),
        mixBootnode("/dns4/broken-01.example.invalid/tcp/30303"),
        mixBootnode("/ip4/127.0.0.1/tcp/60132"),
        mixBootnode("/dns4/broken-02.example.invalid/tcp/30303"),
      ],
      RaisingResolver(),
    )

    check:
      node.getMixNodePoolSize() == 2
      logos_delivery_mix_bootnode_resolve_failures.value() - droppedBefore == 2.0
    await node.stop()

  asyncTest "a name that answers with two addresses is one pool member with two addresses":
    let entry = mixBootnode("/dns4/delivery-01.example.invalid/tcp/30303")
    let peerId = parsePeerInfo(entry.multiAddr).get().peerId
    let node = await mountWith(@[entry], TwoAddressResolver())

    check:
      node.getMixNodePoolSize() == 1
      node.peerManager.switch.peerStore.getPeer(peerId).addrs.len == 2
    await node.stop()

type NeverResolver = ref object of NameResolver
  waits: seq[Future[void].Raising([CancelledError])]

method resolveTxt(
    self: NeverResolver, address: string
): Future[seq[string]] {.async: (raises: [CancelledError]).} =
  return @[]

method resolveIp(
    self: NeverResolver, address: string, port: Port, domain: Domain = Domain.AF_UNSPEC
): Future[seq[TransportAddress]] {.
    async: (raises: [CancelledError, TransportAddressError])
.} =
  let wait = sleepAsync(chronos.minutes(10))
  self.waits.add(wait)
  await wait
  return @[]

type SlowNameResolver = ref object of NameResolver
  ## Answers at once, except a `slow-*` name, which never answers.

method resolveTxt(
    self: SlowNameResolver, address: string
): Future[seq[string]] {.async: (raises: [CancelledError]).} =
  return @[]

method resolveIp(
    self: SlowNameResolver,
    address: string,
    port: Port,
    domain: Domain = Domain.AF_UNSPEC,
): Future[seq[TransportAddress]] {.
    async: (raises: [CancelledError, TransportAddressError])
.} =
  if address.startsWith("slow-"):
    await sleepAsync(chronos.minutes(10))
  return @[initTAddress("127.0.0.1", port)]

type GatedResolver = ref object of NameResolver ## Answers once `gate` completes.
  gate: Future[void]

method resolveTxt(
    self: GatedResolver, address: string
): Future[seq[string]] {.async: (raises: [CancelledError]).} =
  return @[]

method resolveIp(
    self: GatedResolver, address: string, port: Port, domain: Domain = Domain.AF_UNSPEC
): Future[seq[TransportAddress]] {.
    async: (raises: [CancelledError, TransportAddressError])
.} =
  # `join` so a cancelled lookup leaves the gate open for the next one.
  await self.gate.join()
  return @[initTAddress("127.0.0.1", port)]

suite "Waku Mix - name resolution in the background":
  ## The mount does not wait for the names. A name that does not answer within
  ## `MixNodeResolveTimeout` is dropped; the first case takes the full 10 s.
  asyncTest "a name that never answers is dropped, and the mount does not wait for it":
    let resolver = NeverResolver()
    let node = newTestWakuNode(generateSecp256k1Key(), nameResolver = resolver)
    let keys = generateKeyPair().expect("mix key pair")
    let pid = PeerId.init(generateSecp256k1Key()).tryGet()
    let mount = node.mountMix(
      DefaultClusterId,
      keys.privateKey,
      @[
        MixNodePubInfo(
          multiAddr: "/ip4/127.0.0.1/tcp/60401/p2p/" & $pid, pubKey: keys.publicKey
        ),
        MixNodePubInfo(
          multiAddr: "/dns4/never-01.invalid/tcp/30303/p2p/" & $pid,
          pubKey: keys.publicKey,
        ),
        MixNodePubInfo(
          multiAddr: "/dns4/never-02.invalid/tcp/30303/p2p/" & $pid,
          pubKey: keys.publicKey,
        ),
      ],
    )
    check await mount.withTimeout(chronos.seconds(1)) # no wait on the names
    if mount.finished():
      mount.read().isOkOr:
        raiseAssert "mount failed: " & error
    check node.getMixNodePoolSize() == 1 # the literal, at once

    # A limit well above the 10 s budget, so a lookup left running fails here.
    check await node.mixNodesResolved().withTimeout(chronos.seconds(30))
    check:
      node.getMixNodePoolSize() == 1
      resolver.waits.len == 2
    for wait in resolver.waits:
      check wait.cancelled()
    await node.stop()

  asyncTest "stopping the node cancels a lookup still pending":
    ## No DNS request outlives the node.
    let resolver = NeverResolver()
    let node = newTestWakuNode(generateSecp256k1Key(), nameResolver = resolver)
    let keys = generateKeyPair().expect("mix key pair")
    let pid = PeerId.init(generateSecp256k1Key()).tryGet()
    (
      await node.mountMix(
        DefaultClusterId,
        keys.privateKey,
        @[
          MixNodePubInfo(
            multiAddr: "/ip4/127.0.0.1/tcp/60402/p2p/" & $pid, pubKey: keys.publicKey
          ),
          MixNodePubInfo(
            multiAddr: "/dns4/never-03.invalid/tcp/30303/p2p/" & $pid,
            pubKey: keys.publicKey,
          ),
          MixNodePubInfo(
            multiAddr: "/dns4/never-04.invalid/tcp/30303/p2p/" & $pid,
            pubKey: keys.publicKey,
          ),
        ],
      )
    ).isOkOr:
      raiseAssert "mount failed: " & error
    await sleepAsync(chronos.milliseconds(50))
    check resolver.waits.len == 2

    check await node.stop().withTimeout(chronos.seconds(5))
    check node.mixNodeResolution.cancelled()
    for wait in resolver.waits:
      check wait.cancelled()

  asyncTest "each node joins the pool when its own name answers":
    ## A name that never answers does not hold back the others.
    let node =
      newTestWakuNode(generateSecp256k1Key(), nameResolver = SlowNameResolver())
    let keys = generateKeyPair().expect("mix key pair")
    (
      await node.mountMix(
        DefaultClusterId,
        keys.privateKey,
        @[
          mixBootnode("/dns4/fast-01.invalid/tcp/30303"),
          mixBootnode("/dns4/fast-02.invalid/tcp/30303"),
          mixBootnode("/dns4/fast-03.invalid/tcp/30303"),
          mixBootnode("/dns4/fast-04.invalid/tcp/30303"),
          mixBootnode("/dns4/slow-01.invalid/tcp/30303"),
        ],
      )
    ).isOkOr:
      raiseAssert "mount failed: " & error
    await sleepAsync(chronos.milliseconds(100))

    check:
      node.getMixNodePoolSize() == 4
      not node.mixNodeResolution.finished()
    await node.stop()

  asyncTest "a start after a stop resumes the names still pending":
    let resolver = GatedResolver(gate: newFuture[void]("gate"))
    let node = newTestWakuNode(generateSecp256k1Key(), nameResolver = resolver)
    let keys = generateKeyPair().expect("mix key pair")
    (
      await node.mountMix(
        DefaultClusterId,
        keys.privateKey,
        @[mixBootnode("/dns4/gated-01.invalid/tcp/30303")],
      )
    ).isOkOr:
      raiseAssert "mount failed: " & error
    await node.start()
    await node.stop()
    check:
      node.mixNodeResolution.cancelled()
      node.getMixNodePoolSize() == 0

    await node.start()
    resolver.gate.complete()
    check await node.mixNodesResolved().withTimeout(chronos.seconds(5))
    check node.getMixNodePoolSize() == 1
    await node.stop()
