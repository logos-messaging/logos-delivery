{.used.}

import std/[options, sequtils, times]
import chronos, testutils/unittests, stew/byteutils, libp2p/[switch, peerinfo]
import ../testlib/[common, wakucore, wakunode, testasync]

import
  waku,
  waku/[waku_node, waku_core, waku_relay/protocol, common/broker/broker_context],
  waku/node/health_monitor/[topic_health, health_status, protocol_health, health_report],
  waku/requests/health_requests,
  waku/requests/node_requests,
  waku/events/health_events,
  waku/common/waku_protocol,
  waku/factory/waku_conf

const TestTimeout = chronos.seconds(10)
const DefaultShard = PubsubTopic("/waku/2/rs/1/0")
const TestContentTopic = ContentTopic("/waku/2/default-content/proto")

proc dummyHandler(
    topic: PubsubTopic, msg: WakuMessage
): Future[void] {.async, gcsafe.} =
  discard

proc waitForConnectionStatus(
    brokerCtx: BrokerContext, expected: ConnectionStatus
): Future[void] {.async.} =
  var future = newFuture[void]("waitForConnectionStatus")

  let handler: EventConnectionStatusChangeListenerProc = proc(
      e: EventConnectionStatusChange
  ) {.async: (raises: []), gcsafe.} =
    if not future.finished:
      if e.connectionStatus == expected:
        future.complete()

  let handle = EventConnectionStatusChange.listen(brokerCtx, handler).valueOr:
    raiseAssert error

  try:
    if not await future.withTimeout(TestTimeout):
      raiseAssert "Timeout waiting for status: " & $expected
  finally:
    EventConnectionStatusChange.dropListener(brokerCtx, handle)

proc waitForShardHealthy(
    brokerCtx: BrokerContext
): Future[EventShardTopicHealthChange] {.async.} =
  var future = newFuture[EventShardTopicHealthChange]("waitForShardHealthy")

  let handler: EventShardTopicHealthChangeListenerProc = proc(
      e: EventShardTopicHealthChange
  ) {.async: (raises: []), gcsafe.} =
    if not future.finished:
      if e.health == TopicHealth.MINIMALLY_HEALTHY or
          e.health == TopicHealth.SUFFICIENTLY_HEALTHY:
        future.complete(e)

  let handle = EventShardTopicHealthChange.listen(brokerCtx, handler).valueOr:
    raiseAssert error

  try:
    if await future.withTimeout(TestTimeout):
      return future.read()
    else:
      raiseAssert "Timeout waiting for shard health event"
  finally:
    EventShardTopicHealthChange.dropListener(brokerCtx, handle)

suite "LM API health checking":
  var
    serviceNode {.threadvar.}: WakuNode
    client {.threadvar.}: Waku
    servicePeerInfo {.threadvar.}: RemotePeerInfo

  asyncSetup:
    lockNewGlobalBrokerContext:
      serviceNode =
        newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
      (await serviceNode.mountRelay()).isOkOr:
        raiseAssert error
      serviceNode.mountMetadata(1, @[0'u16]).isOkOr:
        raiseAssert error
      await serviceNode.mountLibp2pPing()
      await serviceNode.start()

    servicePeerInfo = serviceNode.peerInfo.toRemotePeerInfo()
    serviceNode.wakuRelay.subscribe(DefaultShard, dummyHandler)

    lockNewGlobalBrokerContext:
      let conf = NodeConfig.init(
        mode = WakuMode.Core,
        networkingConfig =
          NetworkingConfig(listenIpv4: "0.0.0.0", p2pTcpPort: 0, discv5UdpPort: 0),
        protocolsConfig = ProtocolsConfig.init(
          entryNodes = @[],
          clusterId = 1'u16,
          autoShardingConfig = AutoShardingConfig(numShardsInCluster: 1),
        ),
      )

      client = (await createNode(conf)).valueOr:
        raiseAssert error
      (await startWaku(addr client)).isOkOr:
        raiseAssert error

  asyncTeardown:
    discard await client.stop()
    await serviceNode.stop()

  asyncTest "RequestShardTopicsHealth, check PubsubTopic health":
    client.node.wakuRelay.subscribe(DefaultShard, dummyHandler)
    await client.node.connectToNodes(@[servicePeerInfo])

    var isHealthy = false
    let start = Moment.now()
    while Moment.now() - start < TestTimeout:
      let req = RequestShardTopicsHealth.request(client.brokerCtx, @[DefaultShard]).valueOr:
        raiseAssert "RequestShardTopicsHealth failed"

      if req.topicHealth.len > 0:
        let h = req.topicHealth[0].health
        if h == TopicHealth.MINIMALLY_HEALTHY or h == TopicHealth.SUFFICIENTLY_HEALTHY:
          isHealthy = true
          break
      await sleepAsync(chronos.milliseconds(100))

    check isHealthy == true

  asyncTest "RequestShardTopicsHealth, check disconnected PubsubTopic":
    const GhostShard = PubsubTopic("/waku/2/rs/1/666")
    client.node.wakuRelay.subscribe(GhostShard, dummyHandler)

    let req = RequestShardTopicsHealth.request(client.brokerCtx, @[GhostShard]).valueOr:
      raiseAssert "Request failed"

    check req.topicHealth.len > 0
    check req.topicHealth[0].health == TopicHealth.UNHEALTHY

  asyncTest "RequestProtocolHealth, check relay status":
    await client.node.connectToNodes(@[servicePeerInfo])

    var isReady = false
    let start = Moment.now()
    while Moment.now() - start < TestTimeout:
      let relayReq = await RequestProtocolHealth.request(
        client.brokerCtx, WakuProtocol.RelayProtocol
      )
      if relayReq.isOk() and relayReq.get().healthStatus.health == HealthStatus.READY:
        isReady = true
        break
      await sleepAsync(chronos.milliseconds(100))

    check isReady == true

    let storeReq =
      await RequestProtocolHealth.request(client.brokerCtx, WakuProtocol.StoreProtocol)
    if storeReq.isOk():
      check storeReq.get().healthStatus.health != HealthStatus.READY

  asyncTest "RequestProtocolHealth, check unmounted protocol":
    let req =
      await RequestProtocolHealth.request(client.brokerCtx, WakuProtocol.StoreProtocol)
    check req.isOk()

    let status = req.get().healthStatus
    check status.health == HealthStatus.NOT_MOUNTED
    check status.desc.isNone()

  asyncTest "RequestConnectionStatus, check connectivity state":
    let initialReq = RequestConnectionStatus.request(client.brokerCtx).valueOr:
      raiseAssert "RequestConnectionStatus failed"
    check initialReq.connectionStatus == ConnectionStatus.Disconnected

    await client.node.connectToNodes(@[servicePeerInfo])

    var isConnected = false
    let start = Moment.now()
    while Moment.now() - start < TestTimeout:
      let req = RequestConnectionStatus.request(client.brokerCtx).valueOr:
        raiseAssert "RequestConnectionStatus failed"

      if req.connectionStatus == ConnectionStatus.PartiallyConnected or
          req.connectionStatus == ConnectionStatus.Connected:
        isConnected = true
        break
      await sleepAsync(chronos.milliseconds(100))

    check isConnected == true

  asyncTest "EventConnectionStatusChange, detect connect and disconnect":
    let connectFuture =
      waitForConnectionStatus(client.brokerCtx, ConnectionStatus.PartiallyConnected)

    await client.node.connectToNodes(@[servicePeerInfo])
    await connectFuture

    let disconnectFuture =
      waitForConnectionStatus(client.brokerCtx, ConnectionStatus.Disconnected)
    await client.node.disconnectNode(servicePeerInfo)
    await disconnectFuture

  asyncTest "EventShardTopicHealthChange, detect health improvement":
    client.node.wakuRelay.subscribe(DefaultShard, dummyHandler)

    let healthEventFuture = waitForShardHealthy(client.brokerCtx)

    await client.node.connectToNodes(@[servicePeerInfo])

    let event = await healthEventFuture
    check event.topic == DefaultShard

  asyncTest "RequestHealthReport, check aggregate report":
    let req = await RequestHealthReport.request(client.brokerCtx)

    check req.isOk()

    let report = req.get().healthReport
    check report.nodeHealth == HealthStatus.READY
    check report.protocolsHealth.len > 0
    check report.protocolsHealth.anyIt(it.protocol == $WakuProtocol.RelayProtocol)

  asyncTest "RequestContentTopicsHealth, smoke test":
    let fictionalTopic = ContentTopic("/waku/2/this-does-not-exist/proto")

    let req = RequestContentTopicsHealth.request(client.brokerCtx, @[fictionalTopic])

    check req.isOk()

    let res = req.get()
    check res.contentTopicHealth.len == 1
    check res.contentTopicHealth[0].topic == fictionalTopic
    check res.contentTopicHealth[0].health == TopicHealth.NOT_SUBSCRIBED

  asyncTest "RequestContentTopicsHealth, core mode trivial 1-shard autosharding":
    let cTopic = ContentTopic("/waku/2/my-content-topic/proto")

    let shardReq =
      RequestRelayShard.request(client.brokerCtx, none(PubsubTopic), cTopic)

    check shardReq.isOk()
    let targetShard = $shardReq.get().relayShard

    client.node.wakuRelay.subscribe(targetShard, dummyHandler)
    serviceNode.wakuRelay.subscribe(targetShard, dummyHandler)

    await client.node.connectToNodes(@[servicePeerInfo])

    var isHealthy = false
    let start = Moment.now()
    while Moment.now() - start < TestTimeout:
      let req = RequestContentTopicsHealth.request(client.brokerCtx, @[cTopic]).valueOr:
        raiseAssert "Request failed"

      if req.contentTopicHealth.len > 0:
        let h = req.contentTopicHealth[0].health
        if h == TopicHealth.MINIMALLY_HEALTHY or h == TopicHealth.SUFFICIENTLY_HEALTHY:
          isHealthy = true
          break

      await sleepAsync(chronos.milliseconds(100))

    check isHealthy == true
