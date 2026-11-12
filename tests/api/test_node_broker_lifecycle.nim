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
import sds
import logos_delivery
import
  logos_delivery/waku/waku_core,
  logos_delivery/waku/api/events/discovery_events,
  logos_delivery/waku/requests/[node_state_requests, health_requests],
  logos_delivery/waku/discovery/[peer_discovery_interface, external_service_discovery],
  logos_delivery/waku/waku_rendezvous/client,
  logos_delivery/waku/node/health_monitor/[health_status, node_health_monitor],
  logos_delivery/waku/rln/rln_plugin
import tests/testlib/[wakunodeconf, rest_service]

proc lifecycleConf(rest = false, plugin = false): LogosDeliveryNodeConf =
  var kernel = defaultTestWakuNodeConf(rest = rest)
  kernel.discv5Discovery = Opt.some(true)
  if plugin:
    kernel.pluginKadDiscovery = Opt.some(true)
  else:
    kernel.enableKadDiscovery = Opt.some(true)
  testNodeConf(kernel, EntryLayer.messaging)

proc channelsConf(): LogosDeliveryNodeConf =
  var kernel = defaultTestWakuNodeConf()
  kernel.discv5Discovery = Opt.some(true)
  kernel.enableKadDiscovery = Opt.some(true)
  testNodeConf(kernel, EntryLayer.channels)

proc holdMessagingSubscribe(ctx: BrokerContext) =
  ## Another owner holds MessagingSubscribe, so the messaging layer cannot start.
  let foreign = MessagingSubscribe.setProvider(
    ctx,
    proc(contentTopic: ContentTopic): Result[void, string] =
      ok(),
  )
  doAssert foreign.isOk()

proc failingStopPlugin(): RlnPlugin =
  ## The transport stop awaits the RLN plugin stop, so this plugin fails it.
  RlnPlugin(
    name: "failing-stop",
    stop: proc(): Future[void] {.gcsafe, raises: [].} =
      let fut = newFuture[void]("failing-stop")
      fut.fail(newException(CatchableError, "stop failed"))
      fut,
  )

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

  asyncTest "a REST mount during a REST stop starts no listener":
    ## `stop_node` stops REST while `start_node` can still mount it.
    lockNewGlobalBrokerContext:
      let node = (await LogosDelivery.new(lifecycleConf(rest = true))).valueOr:
        raiseAssert error
      let rest = RestService.new()
      rest.start(node).isOkOr:
        raiseAssert "REST start: " & error
      (await node.start()).isOkOr:
        raiseAssert "start: " & error

      let restStopping = rest.stop(node)
      discard rest.mount(node)
      await restStopping
      check not rest.isListeningToMessagingEvents()

      (await node.stop()).isOkOr:
        raiseAssert error

  asyncTest "REST binds its port again after a stop":
    lockNewGlobalBrokerContext:
      let node = (await LogosDelivery.new(lifecycleConf(rest = true))).valueOr:
        raiseAssert error
      let rest = (await node.startWithRest()).valueOr:
        raiseAssert error
      let port = rest.server.httpServer.address.port
      await rest.stop(node)
      (await node.stop()).isOkOr:
        raiseAssert error

      # The library starts REST again before the node, on the bound port.
      let restarted = rest.start(node)
      check restarted.isOk()
      if restarted.isOk():
        check rest.server.httpServer.address.port == port
        (await node.start()).isOkOr:
          raiseAssert "restart: " & error
        check rest.mount(node).isOk()
        await rest.stop(node)
        (await node.stop()).isOkOr:
          raiseAssert error

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

  asyncTest "a failed start leaves the node stopped":
    ## External service discovery is configured but no plugin is installed, so
    ## start fails after the transport is up.
    lockNewGlobalBrokerContext:
      let ctx = globalBrokerContext()
      let node = (await LogosDelivery.new(lifecycleConf(plugin = true))).valueOr:
        raiseAssert error
      let started = await node.start()
      check:
        started.isErr()
        not node.isRunning()
        nodeStateProvided(ctx) == @[false, false, false, false, false, false]
        RequestConnectionStatus.getCurrentProviderNoArgs(ctx).isNone()

  asyncTest "a failed messaging start stops the transport":
    lockNewGlobalBrokerContext:
      let ctx = globalBrokerContext()
      let node = (await LogosDelivery.new(lifecycleConf())).valueOr:
        raiseAssert error
      # Another owner holds MessagingSubscribe, so the messaging layer cannot start.
      let foreign = MessagingSubscribe.setProvider(
        ctx,
        proc(contentTopic: ContentTopic): Result[void, string] =
          ok(),
      )
      require foreign.isOk()

      let started = await node.start()
      check:
        started.isErr()
        not node.isRunning()
        nodeStateProvided(ctx) == @[false, false, false, false, false, false]
        MessagingSend.getCurrentProvider(ctx).isNone()
        MessagingUnsubscribe.getCurrentProvider(ctx).isNone()
        # The provider of the other owner stays.
        MessagingSubscribe.getCurrentProvider(ctx).present

      # With the other provider gone, the same node starts.
      MessagingSubscribe.clearProvider(ctx)
      (await node.start()).isOkOr:
        raiseAssert "start after the failed one: " & error
      check node.isRunning()
      (await node.stop()).isOkOr:
        raiseAssert error

  asyncTest "a failed start keeps the channels made before start":
    lockNewGlobalBrokerContext:
      let ctx = globalBrokerContext()
      let node = (await LogosDelivery.new(channelsConf())).valueOr:
        raiseAssert error
      holdMessagingSubscribe(ctx)
      let channelId = ChannelId("made-before-start")
      discard node.reliableChannelManager
        .createReliableChannel(
          channelId, ContentTopic("/lifecycle/1/channel/proto"), SdsParticipantID("me")
        )
        .expect("createReliableChannel")

      check:
        (await node.start()).isErr()
        not node.isRunning()
        node.reliableChannelManager.channelExists(channelId)

      MessagingSubscribe.clearProvider(ctx)
      (await node.start()).isOkOr:
        raiseAssert "start after the failed one: " & error
      check node.reliableChannelManager.channelExists(channelId)
      (await node.stop()).isOkOr:
        raiseAssert error

  asyncTest "a second start is a no-op":
    lockNewGlobalBrokerContext:
      let ctx = globalBrokerContext()
      let node = (await LogosDelivery.new(lifecycleConf())).valueOr:
        raiseAssert error
      (await node.start()).isOkOr:
        raiseAssert "first start: " & error

      check:
        (await node.start()).isOk()
        node.lifecycleState == LifecycleState.Running
        node.isRunning()
        MessagingSend.getCurrentProvider(ctx).present

      (await node.stop()).isOkOr:
        raiseAssert error
      check node.lifecycleState == LifecycleState.Stopped

  asyncTest "start refuses a node that is stopping":
    ## The channel layer stops first, so both lower layers are still up when
    ## the start comes.
    lockNewGlobalBrokerContext:
      let node = (await LogosDelivery.new(channelsConf())).valueOr:
        raiseAssert error
      (await node.start()).isOkOr:
        raiseAssert "start: " & error
      discard node.reliableChannelManager
        .createReliableChannel(
          ChannelId("stopping"),
          ContentTopic("/lifecycle/1/stopping/proto"),
          SdsParticipantID("me"),
        )
        .expect("createReliableChannel")

      let stopping = node.stop()
      check:
        node.lifecycleState == LifecycleState.Stopping
        node.messagingClient.started
        node.waku.node.started
        (await node.start()).isErr()

      check:
        (await stopping).isOk()
        node.lifecycleState == LifecycleState.Stopped
        not node.isRunning()

  asyncTest "a stop during a start waits for the start, then stops":
    lockNewGlobalBrokerContext:
      let ctx = globalBrokerContext()
      # The dial to a static node on a closed port makes the start wait.
      var kernel = defaultTestWakuNodeConf()
      kernel.staticnodes =
        @["/ip4/127.0.0.1/tcp/1/p2p/" & $PeerId.random(crypto.newRng()).get()]
      let node = (await LogosDelivery.new(testNodeConf(kernel, EntryLayer.messaging))).valueOr:
        raiseAssert error
      let starting = node.start()
      check:
        node.lifecycleState == LifecycleState.Starting
        (await node.start()).isErr()

      let stopped = await node.stop()
      check:
        starting.finished()
        (await starting).isOk()
        stopped.isOk()
        node.lifecycleState == LifecycleState.Stopped
        not node.isRunning()
        nodeStateProvided(ctx) == @[false, false, false, false, false, false]
        MessagingSend.getCurrentProvider(ctx).isNone()

  asyncTest "a failed messaging start with MessagingUnsubscribe held clears the rest":
    lockNewGlobalBrokerContext:
      let ctx = globalBrokerContext()
      let node = (await LogosDelivery.new(lifecycleConf())).valueOr:
        raiseAssert error
      let foreign = MessagingUnsubscribe.setProvider(
        ctx,
        proc(contentTopic: ContentTopic): Result[void, string] =
          ok(),
      )
      require foreign.isOk()

      check:
        (await node.start()).isErr()
        node.lifecycleState == LifecycleState.Stopped
        not node.isRunning()
        nodeStateProvided(ctx) == @[false, false, false, false, false, false]
        MessagingSend.getCurrentProvider(ctx).isNone()
        MessagingSubscribe.getCurrentProvider(ctx).isNone()
        MessagingUnsubscribe.getCurrentProvider(ctx).present

      MessagingUnsubscribe.clearProvider(ctx)

  asyncTest "a start on a TCP port in use leaves nothing running":
    lockNewGlobalBrokerContext:
      let ctx = globalBrokerContext()
      let held = newSocket()
      held.bindAddr()
      held.listen()
      var kernel = defaultTestWakuNodeConf()
      kernel.tcpPort = held.getLocalAddr()[1]
      kernel.rendezvous = Opt.some(true)
      let node = (await LogosDelivery.new(testNodeConf(kernel, EntryLayer.messaging))).valueOr:
        raiseAssert error
      let rendezvous = node.waku.node.wakuRendezvousClient
      require not rendezvous.isNil()

      check:
        (await node.start()).isErr()
        not node.isRunning()
        not rendezvous.isRunning()
        nodeStateProvided(ctx) == @[false, false, false, false, false, false]

      (await node.stop()).isOkOr:
        raiseAssert "stop after the failed start: " & error
      held.close()

  asyncTest "a stop before start does not stop the transport":
    lockNewGlobalBrokerContext:
      let node = (await LogosDelivery.new(lifecycleConf())).valueOr:
        raiseAssert error
      (await node.stop()).isOkOr:
        raiseAssert error
      # The transport stop sets the node health to SHUTTING_DOWN.
      check:
        (await node.waku.healthMonitor.getNodeHealthReport()).nodeHealth ==
          HealthStatus.INITIALIZING
        node.lifecycleState == LifecycleState.Stopped

  asyncTest "a second stop returns ok":
    lockNewGlobalBrokerContext:
      let node = (await LogosDelivery.new(lifecycleConf())).valueOr:
        raiseAssert error
      (await node.start()).isOkOr:
        raiseAssert error
      (await node.stop()).isOkOr:
        raiseAssert "first stop: " & error
      (await node.stop()).isOkOr:
        raiseAssert "second stop: " & error
      check not node.isRunning()

  asyncTest "a failed stop refuses a start and the next stop retries":
    lockNewGlobalBrokerContext:
      let node = (await LogosDelivery.new(lifecycleConf())).valueOr:
        raiseAssert error
      (await node.start()).isOkOr:
        raiseAssert error
      node.waku.node.rlnPlugin = Opt.some(failingStopPlugin())

      check:
        (await node.stop()).isErr()
        node.lifecycleState == LifecycleState.Stopping
        node.isRunning()
        (await node.start()).isErr()

      node.waku.node.rlnPlugin = Opt.none(RlnPlugin)
      check:
        (await node.stop()).isOk()
        node.lifecycleState == LifecycleState.Stopped
        not node.isRunning()

  asyncTest "a kernel node refuses a start after a failed stop":
    lockNewGlobalBrokerContext:
      let conf = testNodeConf(defaultTestWakuNodeConf(), EntryLayer.kernel)
      let node = (await LogosDelivery.new(conf)).valueOr:
        raiseAssert error
      (await node.start()).isOkOr:
        raiseAssert error
      node.waku.node.rlnPlugin = Opt.some(failingStopPlugin())

      check:
        (await node.stop()).isErr()
        (await node.start()).isErr()

      node.waku.node.rlnPlugin = Opt.none(RlnPlugin)
      check:
        (await node.stop()).isOk()
        not node.isRunning()

  asyncTest "a LogosDelivery built without the stack builder starts and stops":
    lockNewGlobalBrokerContext:
      let built = (await LogosDelivery.new(lifecycleConf())).valueOr:
        raiseAssert error
      let node = LogosDelivery(waku: built.waku, messagingClient: built.messagingClient)

      (await node.start()).isOkOr:
        raiseAssert "start: " & error
      check node.lifecycleState == LifecycleState.Running

      (await node.stop()).isOkOr:
        raiseAssert "stop: " & error
      check node.lifecycleState == LifecycleState.Stopped

  asyncTest "a start after a failed rollback returns an error":
    ## The messaging start fails, and the transport stop of the rollback fails
    ## too, so the transport is still marked as started.
    lockNewGlobalBrokerContext:
      let ctx = globalBrokerContext()
      let node = (await LogosDelivery.new(lifecycleConf())).valueOr:
        raiseAssert error
      holdMessagingSubscribe(ctx)
      node.waku.node.rlnPlugin = Opt.some(failingStopPlugin())

      check:
        (await node.start()).isErr()
        node.lifecycleState == LifecycleState.Stopped
        node.waku.node.started

      MessagingSubscribe.clearProvider(ctx)
      check:
        (await node.start()).isErr()
        not node.messagingClient.started

      # A stop retries the transport stop, and the node then starts again.
      node.waku.node.rlnPlugin = Opt.none(RlnPlugin)
      check:
        (await node.stop()).isOk()
        not node.isRunning()
        (await node.start()).isOk()
        (await node.stop()).isOk()

  asyncTest "a start during the REST stop of a stop returns an error":
    ## `stop_node` passes the REST stop to `stop`, which runs it under the lock.
    lockNewGlobalBrokerContext:
      let node = (await LogosDelivery.new(lifecycleConf(rest = true))).valueOr:
        raiseAssert error
      let rest = (await node.startWithRest()).valueOr:
        raiseAssert error

      let stopping = node.stop(
        proc() {.async: (raises: []).} =
          await rest.stop(node)
      )
      check:
        node.lifecycleState == LifecycleState.Stopping
        rest.server.isNil()
        node.messagingClient.started
        (await node.start()).isErr()

      check:
        (await stopping).isOk()
        node.lifecycleState == LifecycleState.Stopped
        not node.isRunning()
        not rest.isListeningToMessagingEvents()
