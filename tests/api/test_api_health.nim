{.used.}

import std/[options, sequtils, times]
import chronos, testutils/unittests, stew/byteutils, libp2p/[switch, peerinfo]
import ../testlib/[common, wakucore, wakunode, testasync]

import
  waku,
  waku/[waku_node, waku_core, waku_relay/protocol, common/broker/broker_context],
  waku/node/health_monitor/[topic_health, health_status, protocol_health, health_report],
  waku/requests/health_requests,
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

      let conf = NodeConfig.init(
        mode = WakuMode.Core,
        networkingConfig =
          NetworkingConfig(listenIpv4: "0.0.0.0", p2pTcpPort: 0, discv5UdpPort: 0),
        protocolsConfig = ProtocolsConfig.init(entryNodes = @[], clusterId = 1'u16),
      )

      client = (await createNode(conf)).valueOr:
        raiseAssert error
      (await startWaku(addr client)).isOkOr:
        raiseAssert error

    servicePeerInfo = serviceNode.peerInfo.toRemotePeerInfo()
    serviceNode.wakuRelay.subscribe(DefaultShard, dummyHandler)

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
