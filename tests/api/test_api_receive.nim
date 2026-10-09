{.used.}

import results, std/[sequtils, net, sets, os, osproc, tables, tempfiles, strutils]
import chronos, metrics, testutils/unittests, stew/byteutils
import libp2p/[peerid, peerinfo]
import brokers/broker_context
import ../testlib/[wakucore, wakunode, wakunodeconf, testasync, short_intervals]
import ../waku_archive/archive_utils
import logos_delivery/messaging/messaging_client
import logos_delivery/messaging/messaging_metrics
import logos_delivery/messaging/messaging_client_lifecycle
import logos_delivery/messaging/delivery_service/recv_service
import logos_delivery/messaging/delivery_service/recv_service/backfill
import logos_delivery/waku/persistency/persistency
import logos_delivery/waku/requests/health_requests
import logos_delivery/waku/node/health_monitor/health_status
import logos_delivery/waku/api/health
import logos_delivery/api/conf/modes
import logos_delivery/api/conf/logos_delivery_conf
from logos_delivery/waku/waku_store/common import WakuStoreCodec
from logos_delivery/waku/waku_filter_v2/subscriptions import removePeer

import
  logos_delivery,
  logos_delivery/waku/[
    waku_node,
    waku_core,
    node/peer_manager,
    api/events/health_events,
    waku_relay/protocol,
    waku_archive,
    waku_archive/common as archive_common,
  ]
import tools/confutils/cli_args
import logos_delivery/api/conf/messaging_conf

const TestTimeout = chronos.seconds(90)
const IdleTimeout = chronos.seconds(20) ## the longest wait for an idle worker
const MissedPayload = "This message was missed"
const LivePayload = "live before the outage"
const OutagePayload = "archived in the outage"

type ReceiveEventListenerManager = ref object
  brokerCtx: BrokerContext
  receivedListener: MessageReceivedEventListener
  receivedEvent: AsyncEvent
  receivedMessages: seq[WakuMessage]
  receivedSources: seq[MessageSource] ## one per `receivedMessages` entry
  targetCount: int

proc newReceiveEventListenerManager(
    brokerCtx: BrokerContext, expectedCount: int = 1
): ReceiveEventListenerManager =
  let manager = ReceiveEventListenerManager(
    brokerCtx: brokerCtx, receivedMessages: @[], targetCount: expectedCount
  )
  manager.receivedEvent = newAsyncEvent()

  manager.receivedListener = MessageReceivedEvent
    .listen(
      brokerCtx,
      proc(event: MessageReceivedEvent) {.async: (raises: []).} =
        manager.receivedMessages.add(event.message)
        manager.receivedSources.add(event.source)
        if manager.receivedMessages.len >= manager.targetCount:
          manager.receivedEvent.fire()
      ,
    )
    .expect("Failed to listen to MessageReceivedEvent")

  return manager

proc teardown(manager: ReceiveEventListenerManager) {.async.} =
  await MessageReceivedEvent.dropListener(manager.brokerCtx, manager.receivedListener)

proc waitForEvents(
    manager: ReceiveEventListenerManager, timeout: Duration
): Future[bool] {.async.} =
  return await manager.receivedEvent.wait().withTimeout(timeout)

proc createApiNodeConf(
    numShards: uint16 = 1, mode = LogosDeliveryMode.Core
): WakuNodeConf =
  ## The shared test defaults, plus a resolver that stays on this machine: the
  ## restarted child process must not wait on a real DNS server.
  var conf = defaultTestWakuNodeConf(mode = mode, numShards = numShards)
  conf.dnsAddrsNameServers = @[parseIpAddress("127.0.0.1")]
  return conf

proc backfillOverrides(enabled = true): MessagingClientConf =
  return MessagingClientConf(backfillEnabled: Opt.some(enabled))

proc nodeConf(kernel: WakuNodeConf, messaging: MessagingClientConf): LogosDeliveryConf =
  return LogosDeliveryConf(
    kernelConf: KernelConf(kernel), messagingConf: Opt.some(messaging)
  )

type TestNetwork = ref object
  storeNode: WakuNode
  archiveDriver: ArchiveDriver
    ## the store node's archive, for rows the archive would reject
  publisher: WakuNode
  subscriber: LogosDelivery
  storeNodePeerInfo: RemotePeerInfo
  subscribedAt: Timestamp ## just before the subscribe of `testTopic`
  events: ReceiveEventListenerManager
    ## listening from before the subscription, so a message delivered at the
    ## subscribe counts
  ownedRoot: string ## temp storage root created here, removed at teardown

proc setupNetwork(
    testTopic: ContentTopic,
    storageRoot = "",
    knowStorePeer = true,
    messaging = backfillOverrides(),
    mode = LogosDeliveryMode.Core,
    remoteFilter = false,
    numShards: uint16 = 1,
    storeNodeShards: seq[uint16] = @[],
): Future[TestNetwork] {.async.} =
  ## A started subscriber on `testTopic` with one message archived one minute
  ## before its subscription. The first subscribe of a topic gets no history,
  ## so the message must never arrive. It shows a backfill that reaches too
  ## far back. With `knowStorePeer` the store node is a known service peer
  ## that the Store client dials on demand, as a configured store node is.
  ## The root is on disk so a later process reads the records, and an empty
  ## `storageRoot` gets a temporary one. With `remoteFilter` the store node
  ## serves filter. `storeNodeShards` limits the shards the store node
  ## advertises. `testTopic` must autoshard to shard 0.
  let ownedRoot =
    if storageRoot.len == 0:
      createTempDir("recv-api-", "")
    else:
      ""
  let root = if ownedRoot.len > 0: ownedRoot else: storageRoot
  let shard = PubsubTopic("/waku/2/rs/3/0")

  proc dummyHandler(topic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
    discard

  # store node: archive + store + relay, subscribed to the shard
  var storeNode: WakuNode
  var archiveDriver: ArchiveDriver
  lockNewGlobalBrokerContext:
    storeNode = newTestWakuNode(generateSecp256k1Key())
    let advertised =
      if storeNodeShards.len > 0:
        storeNodeShards
      else:
        toSeq(0'u16 ..< numShards)
    storeNode.mountMetadata(TestClusterId, advertised).expect(
      "Failed to mount metadata on storeNode"
    )
    (await storeNode.mountRelay()).expect("Failed to mount relay on storeNode")
    archiveDriver = newSqliteArchiveDriver()
    storeNode.mountArchive(archiveDriver).expect("Failed to mount archive")
    await storeNode.mountStore()
    if remoteFilter:
      await storeNode.mountFilter()
    await storeNode.mountLibp2pPing()
    await storeNode.start()
  storeNode.subscribe((kind: PubsubSub, topic: shard), dummyHandler).expect(
    "Failed to sub storeNode"
  )

  let storeNodePeerInfo = storeNode.peerInfo.toRemotePeerInfo()

  # publisher: relay, connected to the store so its messages get archived
  var publisher: WakuNode
  lockNewGlobalBrokerContext:
    publisher = newTestWakuNode(generateSecp256k1Key())
    publisher.mountMetadata(TestClusterId, toSeq(0'u16 ..< numShards)).expect(
      "Failed to mount metadata on publisher"
    )
    (await publisher.mountRelay()).expect("Failed to mount relay on publisher")
    await publisher.mountLibp2pPing()
    await publisher.start()
  publisher.subscribe((kind: PubsubSub, topic: shard), dummyHandler).expect(
    "Failed to sub publisher"
  )

  await publisher.connectToNodes(@[storeNodePeerInfo])

  var meshFormed = false
  for _ in 0 ..< 50:
    if publisher.wakuRelay.getNumPeersInMesh(shard).valueOr(0) > 0:
      meshFormed = true
      break
    await sleepAsync(100.milliseconds)
  if not meshFormed:
    raiseAssert "publisher<->store relay mesh did not form in time"

  # Started, without peers.
  var subscriber: LogosDelivery
  lockNewGlobalBrokerContext:
    var conf = createApiNodeConf(numShards, mode)
    conf.localStoragePath = root
    subscriber = (await LogosDelivery.new(nodeConf(conf, messaging))).expect(
      "Failed to create subscriber"
    )
    subscriber.shortenIntervals()
    (await subscriber.start()).expect("Failed to start subscriber")

  # Before the subscription by more than the variance of the timestamps, so it
  # is history from before the interest in the topic.
  let missedMsg = WakuMessage(
    payload: MissedPayload.toBytes(),
    contentTopic: testTopic,
    version: 0,
    timestamp: now() - chronos.minutes(1).nanos,
  )
  discard (
    await archiveDriver.put(computeMessageHash(shard, missedMsg), shard, missedMsg)
  ).expect("archive put")

  let events = newReceiveEventListenerManager(subscriber.waku.brokerCtx, 1)
  if knowStorePeer:
    subscriber.waku.node.peerManager.addServicePeer(storeNodePeerInfo, WakuStoreCodec)
  let subscribedAt = now()
  (await subscriber.messagingClient.subscribe(testTopic)).expect("Failed to subscribe")

  return TestNetwork(
    storeNode: storeNode,
    archiveDriver: archiveDriver,
    publisher: publisher,
    subscriber: subscriber,
    storeNodePeerInfo: storeNodePeerInfo,
    subscribedAt: subscribedAt,
    events: events,
    ownedRoot: ownedRoot,
  )

proc teardown(net: TestNetwork) {.async.} =
  if not isNil(net.events):
    await net.events.teardown()
    net.events = nil
  if not isNil(net.subscriber):
    (await net.subscriber.stop()).expect("Failed to stop subscriber")
    net.subscriber = nil
  if not isNil(net.publisher):
    await net.publisher.stop()
    net.publisher = nil
  if not isNil(net.storeNode):
    await net.storeNode.stop()
    net.storeNode = nil
  if net.ownedRoot.len > 0:
    removeDir(net.ownedRoot)
    net.ownedRoot = ""

const RestartTopic = ContentTopic("/waku/2/recv-process-restart/proto")
const TestShard = PubsubTopic("/waku/2/rs/3/0")
const SecondShard = PubsubTopic("/waku/2/rs/3/1") ## shard 1 of a two-shard network
const OfflineCount = 105 ## archived between two subscriber processes, two Store pages
const Hour = chronos.hours(1).nanos

proc nothingMore(
    events: ReceiveEventListenerManager, count: int, window = 3.seconds
): Future[bool] {.async.} =
  ## True when the app has `count` messages, and no other arrives within
  ## `window`. The count comes first, so a message that arrived before the
  ## call counts too.
  if events.receivedMessages.len != count:
    return false
  events.targetCount = count + 1
  events.receivedEvent.clear()
  return not await events.waitForEvents(window)

proc payloads(events: ReceiveEventListenerManager): seq[string] =
  return events.receivedMessages.mapIt(string.fromBytes(it.payload))

proc runRestartedReceiver(
    storageRoot, storePeer: string, expectedCount: int
) {.async.} =
  ## Child process on the same root with a new identity. It must recover
  ## exactly `expectedCount` messages by the backfill, and every
  ## archived message must be among them.
  var conf = createApiNodeConf()
  conf.localStoragePath = storageRoot
  let subscriber = (await LogosDelivery.new(nodeConf(conf, backfillOverrides()))).expect(
    "new process subscriber"
  )
  subscriber.shortenIntervals()
  let events = newReceiveEventListenerManager(subscriber.waku.brokerCtx, expectedCount)
  (await subscriber.start()).expect("start new process subscriber")
  subscriber.waku.node.peerManager.addServicePeer(
    parsePeerInfo(storePeer).get(), WakuStoreCodec
  )
  (await subscriber.messagingClient.subscribe(RestartTopic)).expect("resubscribe")
  doAssert await events.waitForEvents(TestTimeout)
  doAssert await events.nothingMore(expectedCount),
    "expected " & $expectedCount & " recovered messages, got " &
      $events.receivedMessages.len
  let payloads = events.payloads().toHashSet()
  doAssert payloads.len == expectedCount
  for i in 0 ..< OfflineCount:
    doAssert "process-offline-" & $i in payloads
  # Everything a restarted process recovers comes from Store.
  doAssert events.receivedSources.allIt(it == MessageSource.History),
    "recovered messages must be reported as history, got " & $events.receivedSources
  await events.teardown()
  (await subscriber.stop()).expect("stop new process subscriber")

if paramCount() == 4 and paramStr(1) == "--recv-restart-child":
  waitFor runRestartedReceiver(paramStr(2), paramStr(3), parseInt(paramStr(4)))
  quit(QuitSuccess)

proc runRestartedProcess(
    net: TestNetwork, storageRoot: string, expectedCount: int
) {.async.} =
  ## Runs a new process on `storageRoot` until it recovers `expectedCount`
  ## messages.
  let storePeer =
    $net.storeNodePeerInfo.addrs[0] & "/p2p/" & $net.storeNodePeerInfo.peerId
  let child = startProcess(
    getAppFilename(),
    args = @["--recv-restart-child", storageRoot, storePeer, $expectedCount],
    options = {poParentStreams},
  )
  defer:
    if child.running():
      child.terminate()
    child.close()
  let deadline = Moment.now() + TestTimeout + 10.seconds
  while child.running() and Moment.now() < deadline:
    await sleepAsync(50.milliseconds)
  doAssert not child.running(), "restarted process did not finish in time"
  doAssert child.waitForExit() == 0, "restarted process failed"

proc waitForArchived(net: TestNetwork, topic: ContentTopic, count: int) {.async.} =
  for _ in 0 ..< 100:
    let query = archive_common.ArchiveQuery(
      includeData: false, contentTopics: @[topic], pubsubTopic: Opt.some(TestShard)
    )
    let res = await net.storeNode.wakuArchive.findMessages(query)
    if res.isOk() and res.get().hashes.len >= count:
      return
    await sleepAsync(100.milliseconds)
  raiseAssert "messages were not archived in time"

proc archiveAt(
    net: TestNetwork,
    topic: ContentTopic,
    at: Timestamp,
    text: string,
    shard = TestShard,
): Future[WakuMessage] {.async.} =
  ## Puts a message with the timestamp `at` directly into the archive driver,
  ## because the archive rejects a timestamp outside its tolerance.
  let msg = WakuMessage(payload: text.toBytes(), contentTopic: topic, timestamp: at)
  discard (await net.archiveDriver.put(computeMessageHash(shard, msg), shard, msg)).expect(
    "archive put"
  )
  return msg

proc archiveOffline(net: TestNetwork) {.async.} =
  ## Archives `OfflineCount` messages while no subscriber process runs.
  for i in 0 ..< OfflineCount:
    discard await net.archiveAt(RestartTopic, now(), "process-offline-" & $i)

proc knowStorePeer(net: TestNetwork) =
  ## Registers the store node as a service peer. The Store client dials it on demand.
  net.subscriber.waku.node.peerManager.addServicePeer(
    net.storeNodePeerInfo, WakuStoreCodec
  )

proc joinMesh(node: WakuNode, peer: RemotePeerInfo) {.async.} =
  ## Connects `node` to `peer` and waits until it has a relay mesh, so a
  ## message that one relays reaches the other live. Polls the mesh, because
  ## the Store dial can connect them before this.
  await node.connectToNodes(@[peer])
  for _ in 0 ..< 100:
    if node.wakuRelay.getNumPeersInMesh(TestShard).valueOr(0) > 0:
      return
    await sleepAsync(100.milliseconds)
  raiseAssert "the node did not join the relay mesh in time"

proc joinMesh(net: TestNetwork, peer: RemotePeerInfo) {.async.} =
  ## Joins the subscriber to the relay mesh through `peer`.
  await net.subscriber.waku.node.joinMesh(peer)

proc joinMesh(net: TestNetwork) {.async.} =
  ## Joins the subscriber to the relay mesh through the store node.
  await net.joinMesh(net.storeNodePeerInfo)

proc archiveInOutage(
    net: TestNetwork, topic: ContentTopic, offline: Future[void]
): Future[WakuMessage] {.async.} =
  ## Disconnects the subscriber from the store node, waits for `offline`, then
  ## puts one message straight into the archive. Direct insertion keeps Store
  ## the only path, because the relay cache can give a published message at
  ## reconnection.
  await net.subscriber.waku.node.disconnectNode(net.storeNodePeerInfo)
  await offline
  let msg =
    WakuMessage(payload: OutagePayload.toBytes(), contentTopic: topic, timestamp: now())
  await net.storeNode.wakuArchive.handleMessage(TestShard, msg)
  await net.waitForArchived(topic, 2)
  return msg

proc publishLive(net: TestNetwork, topic: ContentTopic, text: string) {.async.} =
  ## A message the subscriber receives live, through the relay mesh. The
  ## publish waits for the mesh of the publisher when it has no peer yet.
  if net.publisher.wakuRelay.getNumPeersInMesh(TestShard).valueOr(0) == 0:
    # The mesh with the store node can drop between phases. Form it again.
    await net.publisher.joinMesh(net.storeNodePeerInfo)
  let msg = WakuMessage(payload: text.toBytes(), contentTopic: topic, timestamp: now())
  for _ in 0 ..< 50:
    let published = await net.publisher.publish(Opt.some(TestShard), msg)
    if published.isOk():
      return
    await sleepAsync(100.milliseconds)
  raiseAssert "the publisher could not publish live in time"

proc requiredAnonymity(): MessagingClientConf =
  ## A `Required` node with an empty mix pool, so `ConnectionStatus` stays
  ## `Disconnected`.
  return MessagingClientConf(
    backfillEnabled: Opt.some(true), anonymityLevel: Opt.some(AnonymityLevel.Required)
  )

proc waitForProtocolHealth(
    waku: Waku, protocol: WakuProtocol, health: HealthStatus
) {.async.} =
  ## Completes once the kernel reports `protocol` at `health`. Registers the
  ## listener, then reads the stored status.
  let future = newFuture[void]("waitForProtocolHealth")
  let handler: EventProtocolHealthChangeListenerProc = proc(
      e: EventProtocolHealthChange
  ) {.async: (raises: []), gcsafe.} =
    if not future.finished and e.protocolHealth.protocol == $protocol and
        e.protocolHealth.health == health:
      future.complete()
  let handle = EventProtocolHealthChange.listen(waku.brokerCtx, handler).valueOr:
    raiseAssert error
  try:
    if waku.reportedProtocolHealth(protocol).health == health:
      return
    if not await future.withTimeout(TestTimeout):
      raiseAssert "Timeout waiting for " & $protocol & " to be " & $health
  finally:
    await EventProtocolHealthChange.dropListener(waku.brokerCtx, handle)

proc noopRelayHandler(topic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
  discard

proc newFilterServiceNode(shardId: uint16): Future[WakuNode] {.async.} =
  ## A started relay and filter service node that advertises shard `shardId` only.
  let shard = PubsubTopic("/waku/2/rs/" & $TestClusterId & "/" & $shardId)
  var node: WakuNode
  lockNewGlobalBrokerContext:
    node = newTestWakuNode(generateSecp256k1Key())
    node.mountMetadata(TestClusterId, @[shardId]).expect("mount metadata")
    (await node.mountRelay()).expect("mount relay")
    await node.mountFilter()
    await node.mountLibp2pPing()
    await node.start()
  let subscribed = node.subscribe((kind: PubsubSub, topic: shard), noopRelayHandler)
  if subscribed.isErr():
    await node.stop()
    raiseAssert "filter service node subscribe: " & subscribed.error
  return node

proc filterSubscriptionHealthy(net: TestNetwork, shard = TestShard): bool =
  ## True when the subscription manager reports `shard`'s filter subscription healthy.
  let shardHealth = RequestEdgeShardHealth.request(net.subscriber.waku.brokerCtx, shard).valueOr:
    return false
  return
    shardHealth.health in
    {TopicHealth.MINIMALLY_HEALTHY, TopicHealth.SUFFICIENTLY_HEALTHY}

proc waitForFilterSubscriptionHealth(
    net: TestNetwork, healthy: bool, shard = TestShard
) {.async.} =
  ## Completes once the subscription manager reports `shard`'s filter
  ## subscription at `healthy`. Registers the listener, then reads the stored
  ## health.
  let future = newFuture[void]("waitForFilterSubscriptionHealth")
  let handler: EventShardTopicHealthChangeListenerProc = proc(
      e: EventShardTopicHealthChange
  ) {.async: (raises: []), gcsafe.} =
    if future.finished or e.topic != shard:
      return
    let isHealthy =
      e.health in {TopicHealth.MINIMALLY_HEALTHY, TopicHealth.SUFFICIENTLY_HEALTHY}
    if isHealthy == healthy:
      future.complete()
  let brokerCtx = net.subscriber.waku.brokerCtx
  let handle = EventShardTopicHealthChange.listen(brokerCtx, handler).valueOr:
    raiseAssert error
  try:
    if net.filterSubscriptionHealthy(shard) == healthy:
      return
    if not await future.withTimeout(TestTimeout):
      raiseAssert "Timeout waiting for the shard to be " &
        (if healthy: "healthy" else: "unhealthy")
  finally:
    await EventShardTopicHealthChange.dropListener(brokerCtx, handle)

proc restartSubscriber(
    net: TestNetwork, root: string, messaging = backfillOverrides()
) {.async.} =
  ## Stops the subscriber and starts a new one on the same root, with a new
  ## event manager that listens from before any subscribe.
  if not net.events.isNil():
    await net.events.teardown()
    net.events = nil
  if not net.subscriber.isNil():
    (await net.subscriber.stop()).expect("stop subscriber")
    net.subscriber = nil
  var conf = createApiNodeConf()
  conf.localStoragePath = root
  lockNewGlobalBrokerContext:
    net.subscriber =
      (await LogosDelivery.new(nodeConf(conf, messaging))).expect("create subscriber")
    net.subscriber.shortenIntervals()
    (await net.subscriber.start()).expect("start subscriber")
  net.events = newReceiveEventListenerManager(net.subscriber.waku.brokerCtx, 1)
  net.knowStorePeer()

proc storedRecords(root: string): Future[Table[BackfillTopic, TopicRecord]] {.async.} =
  ## The topic records on disk, by topic.
  let persistency = Persistency.new(root).expect("open root")
  defer:
    persistency.close()
  let job = persistency.openJob(MessagingJobId).expect("open job")
  return (await job.readTopicRecords()).expect("read records").toTable()

proc storedLastReceivedAt(root: string): Future[Opt[Timestamp]] {.async.} =
  let persistency = Persistency.new(root).expect("open root")
  defer:
    persistency.close()
  let job = persistency.openJob(MessagingJobId).expect("open job")
  return (await job.readLastReceivedAt()).expect("read the last received time")

proc waitForRecord(
    root: string,
    topic: ContentTopic,
    present: bool,
    shard = TestShard,
    gap = Opt.none(bool),
    within = 5.seconds,
): Future[Opt[TopicRecord]] {.async.} =
  ## Waits until the record of `topic` on `shard` exists (or not), and has
  ## the gap bit `gap` when given, because the writes are fire-and-forget.
  let key: BackfillTopic = (shard, topic)
  let deadline = Moment.now() + within
  while Moment.now() < deadline:
    let records = await storedRecords(root)
    if (key in records) == present:
      if not present:
        return Opt.none(TopicRecord)
      if gap.isNone() or records[key].timestampToNowIsGap == gap.get():
        return Opt.some(records[key])
    await sleepAsync(100.milliseconds)
  raiseAssert "the record of " & topic & " did not reach the expected state"

proc waitForStoredLastReceivedAt(root: string): Future[Timestamp] {.async.} =
  ## The last received time on disk, after the write lands.
  for _ in 0 ..< 50:
    let stored = await root.storedLastReceivedAt()
    if stored.isSome():
      return stored.get()
    await sleepAsync(100.milliseconds)
  raiseAssert "no last received time was stored in time"

proc variance(net: TestNetwork): Timestamp =
  ## The timestamp variance of the subscriber, as `shortenIntervals` set it.
  net.subscriber.messagingClient.recvService.timestampVariance.nanos

proc caughtUp(node: LogosDelivery): Future[bool] {.async.} =
  ## True when the worker goes idle within `IdleTimeout`. A fill takes a few
  ## seconds, so a longer wait is a stall, as a wait for the retry period
  ## would be.
  let idle = node.messagingClient.recvService.backfillWaitForIdle()
  if not await idle.withTimeout(IdleTimeout):
    return false
  return idle.read()

proc caughtUp(net: TestNetwork): Future[bool] =
  net.subscriber.caughtUp()

proc waitOutage(net: TestNetwork): Future[void] =
  ## Completes when the kernel reports relay NOT_READY.
  return waitForProtocolHealth(
    net.subscriber.waku, WakuProtocol.RelayProtocol, HealthStatus.NOT_READY
  )

proc waitLive(net: TestNetwork): Future[void] =
  ## Completes when the kernel reports relay READY.
  return waitForProtocolHealth(
    net.subscriber.waku, WakuProtocol.RelayProtocol, HealthStatus.READY
  )

proc runOutage(net: TestNetwork, topic: ContentTopic): Future[seq[string]] {.async.} =
  ## A live message, then an outage with one archived message, then a
  ## reconnection. Returns the payloads that the app got, in order.
  let events = net.events
  check await net.caughtUp()
  await net.joinMesh()
  await net.waitLive()
  await net.publishLive(topic, LivePayload)
  check await events.waitForEvents(TestTimeout)
  discard await net.archiveInOutage(topic, net.waitOutage())
  events.targetCount = 2
  events.receivedEvent.clear()
  await net.subscriber.waku.node.connectToNodes(@[net.storeNodePeerInfo])
  check await events.waitForEvents(TestTimeout)
  check await net.caughtUp()
  check await events.nothingMore(2)
  return events.payloads()

## Few multi-phase cases. Each `test` block costs three GC-tracked globals, and
## the refc runtime caps the waku test binary at 3500.

suite "Messaging API, Receive Service (backfill)":
  asyncTest "a first subscribe gets no history, and an outage of live delivery is filled from Store":
    let root = createTempDir("recv-api-outage-", "")
    defer:
      removeDir(root)
    let topic = ContentTopic("/waku/2/recv-outage/proto")
    let net = await setupNetwork(topic, root)
    defer:
      await net.teardown()
    let events = net.events
    # Phase 1: the node has no peer yet, so live delivery is in an outage, and
    # the record is a gap from the subscribe. The message archived before the
    # subscribe is outside it, and never arrives.
    check await net.caughtUp()
    check await events.nothingMore(0)
    let record = await root.waitForRecord(topic, present = true)
    check record.get().timestamp >= net.subscribedAt - net.variance
    # Phase 2: a message arrives live, then an outage (relay NOT_READY, one
    # message archived meanwhile, relay READY again). The worker fetches the
    # message of the outage from Store. Nothing from before the subscribe. The
    # metrics count the message of the outage as history.
    let history = $MessageSource.History
    let countBefore = logos_delivery_recv_messages.value([history])
    let bytesBefore = logos_delivery_recv_message_bytes.value([history])
    let got = await net.runOutage(topic)
    check got == @[LivePayload, OutagePayload]
    check events.receivedSources == @[MessageSource.Live, MessageSource.History]
    check logos_delivery_recv_messages.value([history]) == countBefore + 1
    check logos_delivery_recv_message_bytes.value([history]) ==
      bytesBefore + float64(OutagePayload.len)
    discard await root.waitForRecord(topic, present = true, gap = Opt.some(false))

  asyncTest "a restart fills the gap of the downtime, and off resets the state":
    let root = createTempDir("recv-api-restart-", "")
    defer:
      removeDir(root)
    let topic = ContentTopic("/waku/2/recv-restart-gap/proto")
    let newTopic = ContentTopic("/waku/2/recv-restart-new/proto")
    let net = await setupNetwork(topic, root)
    defer:
      await net.teardown()
    # Phase 1: a live message, then a stop with no unsubscribe. Two messages of
    # the topic and one of a new topic are archived while the process is down.
    check await net.caughtUp()
    await net.joinMesh()
    await net.publishLive(topic, "before the stop")
    check await net.events.waitForEvents(TestTimeout)
    discard await root.waitForStoredLastReceivedAt()
    # The record is live on disk before the stop, so the next start applies
    # the restart outage to a live record.
    discard await root.waitForRecord(
      topic, present = true, gap = Opt.some(false), within = TestTimeout
    )
    (await net.subscriber.stop()).expect("stop")
    net.subscriber = nil
    await net.events.teardown()
    net.events = nil
    discard await net.archiveAt(topic, now(), "while down 1")
    discard await net.archiveAt(topic, now(), "while down 2")
    discard await net.archiveAt(newTopic, now() - Hour, "new topic while down")
    # Phase 2: the next run. The subscribe of the topic that the app had
    # fills the gap. A topic that the app never had gets nothing.
    await net.restartSubscriber(root)
    net.events.targetCount = 2
    (await net.subscriber.messagingClient.subscribe(topic)).expect("subscribe")
    (await net.subscriber.messagingClient.subscribe(newTopic)).expect("subscribe new")
    check await net.events.waitForEvents(TestTimeout)
    check await net.caughtUp()
    check await net.events.nothingMore(2)
    let got = net.events.payloads()
    check "while down 1" in got and "while down 2" in got
    check "new topic while down" notin got
    check MissedPayload notin got
    check net.events.receivedSources.allIt(it == MessageSource.History)
    # Phase 3: a start with the flag off deletes the state. The disk check
    # shows the reset. The downtime is not fetched. A later start with the
    # flag on starts clean. The message is outside the variance of a
    # subscribe, so no record has it in its gap.
    (await net.subscriber.stop()).expect("stop")
    net.subscriber = nil
    discard await net.archiveAt(topic, now() - Hour, "while down 3")
    await net.restartSubscriber(root, backfillOverrides(false))
    (await net.subscriber.messagingClient.subscribe(topic)).expect("subscribe")
    check await net.caughtUp()
    check await net.events.nothingMore(0)
    check (await root.storedRecords()).len == 0
    check (await root.storedLastReceivedAt()).isNone()
    (await net.subscriber.stop()).expect("stop")
    net.subscriber = nil
    await net.restartSubscriber(root)
    let subscribedAt = now()
    (await net.subscriber.messagingClient.subscribe(topic)).expect("subscribe")
    check await net.caughtUp()
    check await net.events.nothingMore(0)
    # The record is new, from the subscribe and not from the downtime.
    let fresh = (await root.waitForRecord(topic, present = true)).get()
    check fresh.timestamp >= subscribedAt - net.variance

  asyncTest "an unsubscribe deletes the record, and a subscribe in an outage is a gap":
    let root = createTempDir("recv-api-unsub-", "")
    defer:
      removeDir(root)
    let topic = ContentTopic("/waku/2/recv-unsub/proto")
    let outageTopic = ContentTopic("/waku/2/recv-in-outage/proto")
    let net = await setupNetwork(topic, root)
    defer:
      await net.teardown()
    let events = net.events
    check await net.caughtUp()
    await net.joinMesh()
    await net.waitLive()
    # Phase 1: the unsubscribe deletes the record, gap included. A message
    # archived in an outage before the unsubscribe never arrives, and the next
    # subscribe makes a new live record.
    discard await root.waitForRecord(
      topic, present = true, gap = Opt.some(false), within = IdleTimeout
    )
    await net.subscriber.waku.node.disconnectNode(net.storeNodePeerInfo)
    await net.waitOutage()
    # Inside the gap, which starts two variances before the fill of the start
    # outage, and outside the variance of the next subscribe.
    discard await net.archiveAt(
      topic, now() - 3 * net.variance div 2, "in an outage before the unsubscribe"
    )
    net.subscriber.messagingClient.unsubscribe(topic).expect("unsubscribe")
    discard await root.waitForRecord(topic, present = false)
    await net.subscriber.waku.node.connectToNodes(@[net.storeNodePeerInfo])
    await net.waitLive()
    let resubscribedAt = now()
    (await net.subscriber.messagingClient.subscribe(topic)).expect("subscribe again")
    let again = await root.waitForRecord(
      topic, present = true, gap = Opt.some(false), within = IdleTimeout
    )
    check again.get().timestamp >= resubscribedAt - net.variance
    check await net.caughtUp()
    check await events.nothingMore(0)
    # Phase 2: an outage. A topic that the app subscribes in the outage is a
    # gap from its subscribe. Its messages of the outage come from Store, and
    # nothing from before its subscribe.
    discard await net.archiveAt(outageTopic, now() - Hour, "before its subscribe")
    await net.subscriber.waku.node.disconnectNode(net.storeNodePeerInfo)
    await net.waitOutage()
    (await net.subscriber.messagingClient.subscribe(outageTopic)).expect(
      "subscribe in outage"
    )
    let inOutage = await root.waitForRecord(outageTopic, present = true)
    check inOutage.get().timestampToNowIsGap
    discard await net.archiveAt(outageTopic, now(), "in the outage")
    discard await net.archiveAt(topic, now(), "the old topic in the outage")
    events.targetCount = 2
    events.receivedEvent.clear()
    await net.subscriber.waku.node.connectToNodes(@[net.storeNodePeerInfo])
    check await events.waitForEvents(TestTimeout)
    check await net.caughtUp()
    check await events.nothingMore(2)
    let got = events.payloads()
    check "in the outage" in got and "the old topic in the outage" in got
    check "before its subscribe" notin got
    check events.receivedSources.allIt(it == MessageSource.History)

  asyncTest "a messaging client restart keeps the subscriptions and fills their downtime":
    ## The subscriptions are in place before the service starts again, so
    ## the service seeds them at start, after it reads the records.
    let root = createTempDir("recv-api-client-restart-", "")
    defer:
      removeDir(root)
    let topic = ContentTopic("/waku/2/recv-client-restart/proto")
    let net = await setupNetwork(topic, root)
    defer:
      await net.teardown()
    check await net.caughtUp()
    await net.joinMesh()
    await net.waitLive()
    discard await root.waitForRecord(
      topic, present = true, gap = Opt.some(false), within = IdleTimeout
    )
    await net.subscriber.messagingClient.stop()
    discard await net.archiveAt(topic, now(), "while the client was stopped")
    check net.subscriber.messagingClient.start().isOk()
    check await net.events.waitForEvents(TestTimeout)
    check await net.caughtUp()
    check await net.events.nothingMore(1)
    check net.events.payloads() == @["while the client was stopped"]
    check net.events.receivedSources == @[MessageSource.History]

  asyncTest "with the flag off, an outage is filled the same way":
    let root = createTempDir("recv-api-flag-off-", "")
    defer:
      removeDir(root)
    let topic = ContentTopic("/waku/2/recv-flag-off/proto")
    let net = await setupNetwork(topic, root, messaging = backfillOverrides(false))
    defer:
      await net.teardown()
    let got = await net.runOutage(topic)
    check got == @[LivePayload, OutagePayload]
    check (await root.storedRecords()).len == 0

  asyncTest "a new process recovers what was archived while it was down":
    ## The first session has the topic. The next process subscribes it again,
    ## and recovers all messages archived while stopped, across two Store
    ## pages. The message from before the first subscribe stays out.
    let root = createTempDir("recv-api-process-", "")
    defer:
      removeDir(root)
    let net = await setupNetwork(RestartTopic, root)
    defer:
      await net.teardown()
    check await net.caughtUp()
    (await net.subscriber.stop()).expect("stop previous session")
    net.subscriber = nil
    await net.archiveOffline()
    await net.runRestartedProcess(root, OfflineCount)

  asyncTest "a Store peer that appears while live delivery is up wakes the worker":
    ## The node is live through a relay peer with no Store. The worker waits
    ## for a Store peer. The peer event of the Store connection ends the wait.
    let root = createTempDir("recv-api-store-peer-", "")
    defer:
      removeDir(root)
    let topic = ContentTopic("/waku/2/recv-store-peer/proto")
    let net = await setupNetwork(topic, root, knowStorePeer = false)
    defer:
      await net.teardown()
    let subscribedAt = now()
    discard await root.waitForRecord(topic, present = true, gap = Opt.some(true))
    await net.joinMesh(net.publisher.peerInfo.toRemotePeerInfo())
    await net.waitLive()
    net.knowStorePeer()
    await net.subscriber.waku.node.connectToNodes(@[net.storeNodePeerInfo])
    # The first page of the gap moves the record within seconds, far below
    # `BackfillRetryPeriod`.
    checkUntilTimeoutCustom(IdleTimeout, 100.milliseconds):
      (await root.storedRecords()).getOrDefault((TestShard, topic)).timestamp >
        subscribedAt - net.variance

  asyncTest "Edge: a lost filter subscription is an outage, and its gap is filled":
    ## The filter service drops the subscription while the connection stays.
    ## The subscription manager notices on its next ping and subscribes
    ## again. The message archived in between comes from Store.
    let topic = ContentTopic("/waku/2/recv-edge-filter/proto")
    let net = await setupNetwork(
      topic,
      messaging = requiredAnonymity(),
      mode = LogosDeliveryMode.Edge,
      remoteFilter = true,
    )
    defer:
      await net.teardown()
    let events = net.events
    # The subscription manager subscribes through a connected filter peer.
    await net.subscriber.waku.node.connectToNodes(@[net.storeNodePeerInfo])
    await net.waitForFilterSubscriptionHealth(healthy = true)
    check await net.caughtUp()
    check await events.nothingMore(0)
    net.subscriber.waku.node.subscriptionManager.edgeFilterSubLoopDebounce = 1.seconds
    let offline = net.waitForFilterSubscriptionHealth(healthy = false)
    await net.storeNode.wakuFilter.subscriptions.removePeer(
      net.subscriber.waku.node.switch.peerInfo.peerId
    )
    await offline
    let gapMsg = await net.archiveAt(
      topic, now(), "archived while the filter subscription was gone"
    )
    check await events.waitForEvents(TestTimeout)
    check events.receivedMessages.len == 1 and
      events.receivedMessages[0].payload == gapMsg.payload
    check events.receivedSources == @[MessageSource.History]

  asyncTest "Edge: a topic on a shard with no filter service is a gap, filled when the shard gets one":
    ## With two shards, `/recv-a/1` maps to shard 0 and `/recv-b/1` to shard 1.
    ## No service peer advertises shard 1, so its filter subscription stays
    ## down, and the node is in an outage until shard 1 gets a filter service.
    let topicA = ContentTopic("/recv-a/1/edge-two-shards/proto")
    let topicB = ContentTopic("/recv-b/1/edge-two-shards/proto")
    let root = createTempDir("recv-api-two-shards-", "")
    defer:
      removeDir(root)
    let net = await setupNetwork(
      topicA,
      root,
      messaging = requiredAnonymity(),
      mode = LogosDeliveryMode.Edge,
      remoteFilter = true,
      numShards = 2,
      storeNodeShards = @[0'u16],
    )
    defer:
      await net.teardown()
    let events = net.events
    await net.subscriber.waku.node.connectToNodes(@[net.storeNodePeerInfo])
    await net.waitForFilterSubscriptionHealth(healthy = true)
    check await net.caughtUp()
    check await events.nothingMore(0)
    # The subscribe of B puts live delivery in an outage, so B is a gap from its
    # subscribe, and A is a gap too.
    (await net.subscriber.messagingClient.subscribe(topicB)).expect("subscribe B")
    let recordB = await root.waitForRecord(topicB, present = true, SecondShard)
    check recordB.get().timestampToNowIsGap
    check not net.filterSubscriptionHealthy(SecondShard)
    let gapMsg = await net.archiveAt(
      topicB, now(), "archived before a filter service for its shard", SecondShard
    )
    # Shard 1 gets its filter service. The worker fills the gap of B.
    let filterNode = await newFilterServiceNode(1'u16)
    defer:
      await filterNode.stop()
    let healthyB = net.waitForFilterSubscriptionHealth(healthy = true, SecondShard)
    await net.subscriber.waku.node.connectToNodes(
      @[filterNode.peerInfo.toRemotePeerInfo()]
    )
    await healthyB
    check await events.waitForEvents(TestTimeout)
    check events.receivedMessages.len == 1 and
      events.receivedMessages[0].payload == gapMsg.payload
    check events.receivedSources == @[MessageSource.History]
    check await net.caughtUp()
    check await events.nothingMore(1)

  asyncTest "messaging runs without durable storage":
    ## Phase 1: a started node with `:memory:` keeps the records in memory.
    block:
      var node: LogosDelivery
      lockNewGlobalBrokerContext:
        node = (await LogosDelivery.new(testNodeConf(createApiNodeConf()))).expect(
          "create node"
        )
        node.shortenIntervals()
        (await node.start()).expect("start node")
      check GetPersistency.request(node.waku.brokerCtx).isOk()
      let topic = ContentTopic("/waku/2/recv-memory-only/proto")
      (await node.messagingClient.subscribe(topic)).expect("subscribe")
      check await node.caughtUp()
      check node.isRunning()
      (await node.stop()).expect("stop node")
      check not node.isRunning()
    ## Phase 2: no Persistency provider (transport not started). Messaging
    ## starts, and the records stay in memory.
    block:
      var node: LogosDelivery
      lockNewGlobalBrokerContext:
        node = (await LogosDelivery.new(testNodeConf(createApiNodeConf()))).expect(
          "create node"
        )
        node.shortenIntervals()
      check GetPersistency.request(node.waku.brokerCtx).isErr()
      check node.messagingClient.start().isOk()
      (
        await node.messagingClient.subscribe(
          ContentTopic("/waku/2/recv-no-provider/proto")
        )
      ).expect("subscribe")
      check await node.caughtUp()
      check node.isRunning()
      await node.messagingClient.stop()
      check not node.isRunning()
    ## Phase 3: an out-of-range backfill setting fails node creation. The
    ## full range checks are in the unit test.
    let bad = MessagingClientConf(backfillRequestTimeoutSeconds: Opt.some(0'i64))
    lockNewGlobalBrokerContext:
      check (await LogosDelivery.new(nodeConf(createApiNodeConf(), bad))).isErr()
    ## Phase 4: a job whose file path is a directory keeps the records in
    ## memory, with a warning. The node keeps running.
    block:
      let root = createTempDir("recv-api-badjob-", "")
      defer:
        removeDir(root)
      createDir(root / "messaging.db")
      var conf = createApiNodeConf()
      conf.localStoragePath = root
      var node: LogosDelivery
      lockNewGlobalBrokerContext:
        node = (await LogosDelivery.new(nodeConf(conf, backfillOverrides()))).expect(
          "create node"
        )
        node.shortenIntervals()
        (await node.start()).expect("start node")
      (await node.messagingClient.subscribe(ContentTopic("/waku/2/recv-bad-job/proto"))).expect(
        "subscribe"
      )
      check await node.caughtUp()
      check node.isRunning()
      (await node.stop()).expect("stop node")
