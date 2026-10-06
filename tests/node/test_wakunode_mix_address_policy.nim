{.used.}

## The hop address policy of the mix pool (#4352).

import
  std/[net, sequtils, tables],
  testutils/unittests,
  chronos,
  results,
  libp2p/[multiaddress, peerid, peerinfo, peerstore, switch],
  libp2p/crypto/crypto,
  libp2p/stream/connection,
  libp2p/transports/transport,
  libp2p_mix/mix_protocol
import
  logos_delivery/waku/[waku_core, waku_node, waku_mix, waku_lightpush],
  logos_delivery/waku/node/peer_manager,
  logos_delivery/waku/node/peer_manager/waku_peer_store,
  logos_delivery/waku/node/health_monitor/
    [node_health_monitor, protocol_health, health_status],
  logos_delivery/waku/common/waku_protocol,
  logos_delivery/waku/discovery/peer_discovery_interface,
  ../testlib/[wakucore, wakumix, wakunode]

suite "Waku Mix - hop address policy":
  asyncTest "a private address from discovery stays out of the pool":
    let node = await mixNode()

    let privateQuic = node.discover(@["/ip4/192.168.0.42/udp/24959/quic-v1"])
    let privateTcp = node.discover(@["/ip4/10.1.2.3/tcp/30303"])
    let shared = node.discover(@["/ip4/100.64.0.9/tcp/30303"])
    let loopback = node.discover(@["/ip4/127.0.0.1/tcp/30303"])
    let public = node.discover(@["/ip4/1.1.1.1/tcp/30303"])
    let publicQuic = node.discover(@["/ip4/1.1.1.8/udp/24959/quic-v1"])

    check:
      MixNodePool.new(node.switch.peerStore).peerIds().len == 6
      node.getMixNodePoolSize() == 2
      node.inPool(public)
      node.inPool(publicQuic)
      not node.inPool(privateQuic)
      not node.inPool(privateTcp)
      not node.inPool(shared)
      not node.inPool(loopback)

  asyncTest "a private bootstrap entry stays out of the pool":
    let node = await mixNode(
      bootnodes =
        @[bootnode("/ip4/192.168.1.10/tcp/30303"), bootnode("/ip4/1.1.1.2/tcp/30303")]
    )
    check:
      MixNodePool.new(node.switch.peerStore).peerIds().len == 2
      node.getMixNodePoolSize() == 1
      $node.hopOf(node.wakuMix.nodePool.peerIds()[0]) == "/ip4/1.1.1.2/tcp/30303"

  asyncTest "the hop uses the public address of a peer that also has a private one":
    let node = await mixNode()
    let privateFirst =
      node.discover(@["/ip4/192.168.0.7/tcp/30303", "/ip4/1.1.1.3/tcp/30303"])
    let publicFirst =
      node.discover(@["/ip4/1.1.1.4/tcp/30303", "/ip4/192.168.0.8/tcp/30303"])
    check:
      $node.hopOf(privateFirst) == "/ip4/1.1.1.3/tcp/30303"
      $node.hopOf(publicFirst) == "/ip4/1.1.1.4/tcp/30303"

  asyncTest "the address that this node last dialed wins when the policy accepts it":
    let node = await mixNode()
    let peerId = node.discover(@["/ip4/1.1.1.5/tcp/30303"])
    let store = node.switch.peerStore

    store[LastSeenOutboundBook][peerId] =
      Opt.some(MultiAddress.init("/ip4/1.1.1.6/tcp/30304").tryGet())
    check $node.hopOf(peerId) == "/ip4/1.1.1.6/tcp/30304"

    # Other hops cannot dial a private address that this node dialed last, as on a LAN.
    store[LastSeenOutboundBook][peerId] =
      Opt.some(MultiAddress.init("/ip4/192.168.0.9/tcp/30304").tryGet())
    check $node.hopOf(peerId) == "/ip4/1.1.1.5/tcp/30303"

    node.discover(@["/ip4/192.168.0.10/tcp/30303"], peerId)
    check not node.inPool(peerId)

  asyncTest "a relay route needs a relay address that a hop can dial":
    ## With all addresses allowed, `isDialableMA` accepts each relay route. So
    ## only the check of the relay address refuses a wildcard relay.
    let node = await mixNode(mixAddressPolicy(true))
    let relayId = PeerId.init(generateSecp256k1Key()).tryGet()
    let viaLocalRelay =
      node.discover(@["/ip4/192.168.0.5/tcp/4001/p2p/" & $relayId & "/p2p-circuit"])
    let viaWildcardRelay =
      node.discover(@["/ip4/0.0.0.0/tcp/4001/p2p/" & $relayId & "/p2p-circuit"])
    let viaNamedRelay =
      node.discover(@["/dns4/relay.test/tcp/4001/p2p/" & $relayId & "/p2p-circuit"])
    check:
      node.inPool(viaLocalRelay)
      not node.inPool(viaWildcardRelay)
      # The encoder rejects a relay address that is a `dns4` name.
      not node.inPool(viaNamedRelay)

  asyncTest "a relay route is a hop only when all addresses are allowed":
    let relayId = PeerId.init(generateSecp256k1Key()).tryGet()
    let route = "/ip4/1.1.1.7/tcp/4001/p2p/" & $relayId & "/p2p-circuit"
    let node = await mixNode()
    let viaDefault = node.discover(@[route])
    let local = await mixNode(mixAddressPolicy(true))
    let withAllAddresses = local.discover(@[route])
    check:
      not node.inPool(viaDefault)
      local.inPool(withAllAddresses)

  asyncTest "a relayed self hop still ends reply paths":
    let node = await mixNode()
    let relayId = PeerId.init(generateSecp256k1Key()).tryGet()
    let route = MultiAddress
      .init("/ip4/1.1.1.7/tcp/4001/p2p/" & $relayId & "/p2p-circuit")
      .tryGet()
    check:
      node.wakuMix.updateSelfHop(@[route], @[]) == Opt.some(route)
      node.wakuMix.selfHopUsable()

  test "a default node has no transport for a relay route":
    ## `publicDirectAddressPolicy` rejects relay routes because of this.
    let node = newTestWakuNode(generateSecp256k1Key())
    let relayId = PeerId.init(generateSecp256k1Key()).tryGet()
    let route = MultiAddress
      .init("/ip4/1.1.1.7/tcp/4001/p2p/" & $relayId & "/p2p-circuit")
      .tryGet()
    check node.switch.transports.allIt(not it.handles(route))

  asyncTest "the default libp2p policy accepts private addresses":
    let node = await mixNode(defaultAddressPolicy)
    let privateQuic = node.discover(@["/ip4/192.168.0.42/udp/24959/quic-v1"])
    let loopback = node.discover(@["/ip4/127.0.0.1/tcp/30303"])
    check:
      node.inPool(privateQuic)
      node.inPool(loopback)

  test "the option for all addresses selects the policy":
    let privateAddress = MultiAddress.init("/ip4/192.168.0.42/tcp/30303").tryGet()
    check:
      dialableAddrs(mixAddressPolicy(true), [privateAddress]).len == 1
      dialableAddrs(mixAddressPolicy(false), [privateAddress]).len == 0

  asyncTest "readiness, health and paths use the same peers":
    let node = await mixNode()
    var privatePeers: seq[PeerId]
    for i in 1 .. 3:
      privatePeers.add(node.discover(@["/ip4/192.168.2." & $i & "/tcp/30303"]))
    var publicPeers: seq[PeerId]
    for i in 1 .. MinMixPoolSize:
      publicPeers.add(node.discover(@["/ip4/1.1.2." & $i & "/tcp/30303"]))
    let health = NodeHealthMonitor.new(node)
    proc mixHealth(): HealthStatus =
      health.getSyncProtocolHealthInfo(WakuProtocol.MixProtocol).health

    check:
      node.getMixNodePoolSize() == MinMixPoolSize
      node.wakuMix.nodePool.peerIds().len == MinMixPoolSize
    for peerId in node.wakuMix.nodePool.peerIds():
      check:
        peerId in publicPeers
        mixAddressPolicy(false)(node.hopOf(peerId))

    # A lightpush server on a private address cannot be the exit.
    let store = node.switch.peerStore
    store[ProtoBook][privatePeers[0]] = @[WakuLightPushCodec]
    check mixHealth() == HealthStatus.NOT_READY

    store[ProtoBook][publicPeers[0]] = @[WakuLightPushCodec]
    check mixHealth() == HealthStatus.READY

    # The pool keeps the protocols of the exit after a peer store delete.
    store.delete(publicPeers[0])
    check mixHealth() == HealthStatus.READY

    # A failed dial to the one public exit takes readiness away again.
    node.wakuMix.pool.countFailure(publicPeers[0])
    check:
      node.getMixNodePoolSize() == MinMixPoolSize - 1
      mixHealth() == HealthStatus.NOT_READY

  asyncTest "the self hop of a sender behind NAT still ends its reply paths":
    ## The address policy applies only to the hops of other nodes.
    let node = await mixNode()
    let selfHop = MultiAddress.init("/ip4/192.168.1.20/tcp/60000").tryGet()
    check:
      node.wakuMix.updateSelfHop(@[selfHop], @[]) == Opt.some(selfHop)
      node.wakuMix.selfHopUsable()
