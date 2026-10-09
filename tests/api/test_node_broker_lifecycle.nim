{.used.}

## A stopped node keeps nothing registered on its BrokerContext: every
## RequestBroker provider and EventBroker listener installed by the node is
## removed by stop() and installed again by start(). Two exceptions are
## config-level and outlive stop/start by design: GetDiscoveryRequirements and
## the service-discovery plugin install verbs.

import std/[net, options]
import chronos, testutils/unittests
import libp2p/[multiaddress, peerid], libp2p/crypto/crypto
import brokers/broker_context
import logos_delivery
import
  logos_delivery/waku/[waku_core, waku_node],
  logos_delivery/waku/api/events/discovery_events,
  logos_delivery/waku/requests/[node_state_requests, health_requests],
  logos_delivery/waku/discovery/[peer_discovery_interface, external_service_discovery]
import tests/testlib/[testasync, wakunodeconf, rest_service]

proc lifecycleConf(rest = false, plugin = false): LogosDeliveryNodeConf =
  var kernel = defaultTestWakuNodeConf(rest = rest)
  kernel.discv5Discovery = Opt.some(true)
  if plugin:
    kernel.pluginKadDiscovery = Opt.some(true)
  else:
    kernel.enableKadDiscovery = Opt.some(true)
  testNodeConf(kernel, EntryLayer.messaging)

template present(r: untyped): bool =
  r.isSome()

proc nodeStateProvided(ctx: BrokerContext): seq[bool] =
  @[
    GetNodeSwitch.getCurrentProviderNoArgs(ctx).present,
    GetNodePeerManager.getCurrentProviderNoArgs(ctx).present,
    GetNodeEnr.getCurrentProviderNoArgs(ctx).present,
    GetNodeKey.getCurrentProviderNoArgs(ctx).present,
    GetNodePeerInfo.getCurrentProviderNoArgs(ctx).present,
    GetDynamicBootstrapNodes.getCurrentProviderNoArgs(ctx).present,
  ]

proc discv5Peer(): RemotePeerInfo =
  var rpi = RemotePeerInfo.init(
    PeerId.random(crypto.newRng()).get(),
    @[MultiAddress.init("/ip4/10.0.0.1/tcp/60000").get()],
  )
  rpi.origin = PeerOrigin.Discv5
  rpi

suite "LogosDelivery - broker lifecycle":
  asyncTest "stop clears what the node registered; start installs it again":
    lockNewGlobalBrokerContext:
      let ctx = globalBrokerContext()
      let node = (await LogosDelivery.new(lifecycleConf())).valueOr:
        raiseAssert error
      (await node.start()).isOkOr:
        raiseAssert "start: " & error

      check:
        nodeStateProvided(ctx) == @[true, true, true, true, true, true]
        GetDiscoveryRequirements.getCurrentProviderNoArgs(ctx).present
        ServicePeersRequest.getCurrentProvider(ctx).present
        RequestConnectionStatus.getCurrentProviderNoArgs(ctx).present
        RequestHealthReport.getCurrentProviderNoArgs(ctx).present

      # The discv5 bridge listens on the node's context only.
      var bridged = 0
      let disc = node.waku.discv5Discovery
      let counter = PeersDiscovered.listen(
        disc.brokerCtx,
        proc(ev: PeersDiscovered): Future[void] {.async: (raises: []).} =
          inc(bridged),
      )
      check counter.isOk()
      PeersDiscoveredEvent.emit(ctx, PeersDiscoveredEvent(peers: @[discv5Peer()]))
      PeersDiscoveredEvent.emit(
        DefaultBrokerContext, PeersDiscoveredEvent(peers: @[discv5Peer()])
      )
      await sleepAsync(50.milliseconds)
      check bridged == 1 # the default-context emit did not reach this node

      (await node.stop()).isOkOr:
        raiseAssert "stop: " & error

      check:
        nodeStateProvided(ctx) == @[false, false, false, false, false, false]
        ServicePeersRequest.getCurrentProvider(ctx).isNone()
        RequestConnectionStatus.getCurrentProviderNoArgs(ctx).isNone()
        RequestHealthReport.getCurrentProviderNoArgs(ctx).isNone()
        # config-level, kept for the host while the node is stopped
        GetDiscoveryRequirements.getCurrentProviderNoArgs(ctx).present

      PeersDiscoveredEvent.emit(ctx, PeersDiscoveredEvent(peers: @[discv5Peer()]))
      await sleepAsync(50.milliseconds)
      check bridged == 1 # bridge dropped by stop

      # Same instance again: start re-installs everything.
      (await node.start()).isOkOr:
        raiseAssert "restart: " & error
      check:
        nodeStateProvided(ctx) == @[true, true, true, true, true, true]
        ServicePeersRequest.getCurrentProvider(ctx).present
      PeersDiscoveredEvent.emit(ctx, PeersDiscoveredEvent(peers: @[discv5Peer()]))
      await sleepAsync(50.milliseconds)
      check bridged == 2
      (await node.stop()).isOkOr:
        raiseAssert "stop 2: " & error

  asyncTest "a new node on the same context after stop":
    ## Before: the first node's ServicePeersRequest provider outlived stop and
    ## the second LogosDelivery.new failed with "provider already set".
    lockNewGlobalBrokerContext:
      let first = (await LogosDelivery.new(lifecycleConf())).valueOr:
        raiseAssert error
      (await first.start()).isOkOr:
        raiseAssert error
      (await first.stop()).isOkOr:
        raiseAssert error

      let second = (await LogosDelivery.new(lifecycleConf())).valueOr:
        raiseAssert "second node on the same context: " & error
      (await second.start()).isOkOr:
        raiseAssert "second start: " & error
      (await second.stop()).isOkOr:
        raiseAssert error

  asyncTest "messaging REST event listeners live from start to stop":
    lockNewGlobalBrokerContext:
      let node = (await LogosDelivery.new(lifecycleConf(rest = true))).valueOr:
        raiseAssert error
      let rest = (await node.startWithRest()).valueOr:
        raiseAssert error
      check rest.isListeningToMessagingEvents()
      await rest.stop(node)
      (await node.stop()).isOkOr:
        raiseAssert error
      check not rest.isListeningToMessagingEvents()

  asyncTest "plugin install verbs stay registered while stopped":
    lockNewGlobalBrokerContext:
      let ctx = globalBrokerContext()
      let node = (await LogosDelivery.new(lifecycleConf(plugin = true))).valueOr:
        raiseAssert error
      check:
        SetServiceDiscoveryPlugin.getCurrentProvider(ctx).present
        ClearServiceDiscoveryPlugin.getCurrentProviderNoArgs(ctx).present
      (await node.stop()).isOkOr:
        raiseAssert error
      check:
        SetServiceDiscoveryPlugin.getCurrentProvider(ctx).present
        ClearServiceDiscoveryPlugin.getCurrentProviderNoArgs(ctx).present
