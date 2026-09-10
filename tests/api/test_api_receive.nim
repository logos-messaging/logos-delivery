{.used.}

import results, std/[sequtils, net, sets, os, osproc, tempfiles, strutils]
import chronos, testutils/unittests, stew/byteutils
import libp2p/[peerid, peerinfo, crypto/crypto]
import brokers/broker_context
import ../testlib/[common, wakucore, wakunode, testasync]
import ../waku_archive/archive_utils
import logos_delivery/messaging/messaging_client
import logos_delivery/messaging/messaging_client_lifecycle
import logos_delivery/messaging/delivery_service/recv_service
import logos_delivery/messaging/delivery_service/recv_service/backfill
import logos_delivery/waku/persistency/persistency
import logos_delivery/api/events/kernel_events
import logos_delivery/api/conf/logos_delivery_conf
from logos_delivery/waku/waku_store/common import WakuStoreCodec

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
import logos_delivery/waku/factory/waku_conf
import tools/confutils/cli_args
import logos_delivery/api/conf/messaging_conf

const TestTimeout = chronos.seconds(60)

type ReceiveEventListenerManager = ref object
  brokerCtx: BrokerContext
  receivedListener: MessageReceivedEventListener
  receivedEvent: AsyncEvent
  receivedMessages: seq[WakuMessage]
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

proc waitForConnectionStatus(
    brokerCtx: BrokerContext, expected: ConnectionStatus
) {.async.} =
  ## Completes when the node reports `expected`.
  var future = newFuture[void]("waitForConnectionStatus")

  let handler: EventConnectionStatusChangeListenerProc = proc(
      e: EventConnectionStatusChange
  ) {.async: (raises: []), gcsafe.} =
    if not future.finished and e.connectionStatus == expected:
      future.complete()

  let handle = EventConnectionStatusChange.listen(brokerCtx, handler).valueOr:
    raiseAssert error

  try:
    if not await future.withTimeout(TestTimeout):
      raiseAssert "Timeout waiting for status: " & $expected
  finally:
    await EventConnectionStatusChange.dropListener(brokerCtx, handle)

proc createApiNodeConf(numShards: uint16 = 1): WakuNodeConf =
  var conf = MessagingClientConf()
    .toWakuNodeConf(messaging_conf.LogosDeliveryMode.Core).valueOr:
      raiseAssert error
  conf.listenAddress = parseIpAddress("0.0.0.0")
  conf.tcpPort = Port(0)
  conf.discv5UdpPort = Port(0)
  conf.clusterId = Opt.some(3'u16)
  conf.numShardsInNetwork = numShards
  conf.rest = false
  conf.localStoragePath = InMemoryStoragePath
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
  publisher: WakuNode
  subscriber: LogosDelivery
  storeNodePeerInfo: RemotePeerInfo
  missedPayload: seq[byte]
  events: ReceiveEventListenerManager
    ## listening from before the subscription: with a known Store peer the
    ## catch-up delivers as soon as the topic is subscribed
  ownedRoot: string ## temp storage root created here, removed at teardown

proc setupNetwork(
    testTopic: ContentTopic, storageRoot = "", knowStorePeer = true
): Future[TestNetwork] {.async.} =
  ## A started subscriber on `testTopic` with one message archived between its
  ## start and its subscription, so only Store can deliver it. With
  ## `knowStorePeer` the store node is a known service peer that the Store
  ## client dials on demand, as a configured store node is. The root is on
  ## disk so a later process reads the hint; an empty `storageRoot` gets a
  ## temporary one.
  const numShards: uint16 = 1
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
  lockNewGlobalBrokerContext:
    storeNode = newTestWakuNode(generateSecp256k1Key())
    storeNode.mountMetadata(3, toSeq(0'u16 ..< numShards)).expect(
      "Failed to mount metadata on storeNode"
    )
    (await storeNode.mountRelay()).expect("Failed to mount relay on storeNode")
    storeNode.mountArchive(newSqliteArchiveDriver()).expect("Failed to mount archive")
    await storeNode.mountStore()
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
    publisher.mountMetadata(3, toSeq(0'u16 ..< numShards)).expect(
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

  # Started, without peers. The message is archived after the service start
  # and before the subscription, inside the range to catch up.
  var subscriber: LogosDelivery
  lockNewGlobalBrokerContext:
    var conf = createApiNodeConf(numShards)
    conf.localStoragePath = root
    subscriber = (await LogosDelivery.new(nodeConf(conf, backfillOverrides()))).expect(
      "Failed to create subscriber"
    )
    (await subscriber.start()).expect("Failed to start subscriber")

  let missedPayload = "This message was missed".toBytes()
  let missedMsg = WakuMessage(
    payload: missedPayload, contentTopic: testTopic, version: 0, timestamp: now()
  )
  discard (await publisher.publish(Opt.some(shard), missedMsg)).expect(
    "Publish missed msg failed"
  )
  # Relay publish returns before the archive write. The subscription wakes
  # the catch-up, so the message must be archived first.
  block waitArchive:
    for _ in 0 ..< 50:
      let query = archive_common.ArchiveQuery(
        includeData: false, contentTopics: @[testTopic], pubsubTopic: Opt.some(shard)
      )
      let res = await storeNode.wakuArchive.findMessages(query)
      if res.isOk() and res.get().hashes.len > 0:
        break waitArchive
      await sleepAsync(100.milliseconds)
    raiseAssert "Message was not archived in time"

  let events = newReceiveEventListenerManager(subscriber.waku.brokerCtx, 1)
  if knowStorePeer:
    subscriber.waku.node.peerManager.addServicePeer(storeNodePeerInfo, WakuStoreCodec)
  (await subscriber.messagingClient.subscribe(testTopic)).expect("Failed to subscribe")

  return TestNetwork(
    storeNode: storeNode,
    publisher: publisher,
    subscriber: subscriber,
    storeNodePeerInfo: storeNodePeerInfo,
    missedPayload: missedPayload,
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
const OfflineCount = 105 ## archived between two subscriber processes; two Store pages

proc runRestartedReceiver(
    storageRoot, storePeer: string, expectedCount: int, backfillEnabled: bool
) {.async.} =
  ## Child process on the same root with a new identity. It must recover
  ## exactly `expectedCount` messages by automatic catch-up. When it expects
  ## messages, every archived message must be among them.
  var conf = createApiNodeConf()
  conf.localStoragePath = storageRoot
  let subscriber = (
    await LogosDelivery.new(nodeConf(conf, backfillOverrides(backfillEnabled)))
  ).expect("new process subscriber")
  let events =
    newReceiveEventListenerManager(subscriber.waku.brokerCtx, max(expectedCount, 1))
  (await subscriber.start()).expect("start new process subscriber")
  subscriber.waku.node.peerManager.addServicePeer(
    parsePeerInfo(storePeer).get(), WakuStoreCodec
  )
  (await subscriber.messagingClient.subscribe(RestartTopic)).expect("resubscribe")
  if expectedCount == 0:
    await sleepAsync(3.seconds)
  else:
    doAssert await events.waitForEvents(TestTimeout)
    # Wait for a possible over-delivery.
    await sleepAsync(1.seconds)
  doAssert events.receivedMessages.len == expectedCount,
    "expected " & $expectedCount & " recovered messages, got " &
      $events.receivedMessages.len
  let payloads = events.receivedMessages.mapIt(string.fromBytes(it.payload)).toHashSet()
  doAssert payloads.len == expectedCount
  if expectedCount > 0:
    for i in 0 ..< OfflineCount:
      doAssert "process-offline-" & $i in payloads
  await events.teardown()
  (await subscriber.stop()).expect("stop new process subscriber")

if paramCount() == 5 and paramStr(1) == "--recv-restart-child":
  waitFor runRestartedReceiver(
    paramStr(2), paramStr(3), parseInt(paramStr(4)), paramStr(5) == "enabled"
  )
  quit(QuitSuccess)

proc archiveOffline(net: TestNetwork) {.async.} =
  ## Archives `OfflineCount` messages while no subscriber process runs.
  for i in 0 ..< OfflineCount:
    await net.storeNode.wakuArchive.handleMessage(
      TestShard,
      WakuMessage(
        payload: ("process-offline-" & $i).toBytes(),
        contentTopic: RestartTopic,
        timestamp: now(),
      ),
    )

proc runRestartedProcess(
    net: TestNetwork, storageRoot: string, expectedCount: int, backfillEnabled = true
) {.async.} =
  ## Runs a new process on `storageRoot` until it recovers `expectedCount`
  ## messages.
  let storePeer =
    $net.storeNodePeerInfo.addrs[0] & "/p2p/" & $net.storeNodePeerInfo.peerId
  let child = startProcess(
    getAppFilename(),
    args = @[
      "--recv-restart-child",
      storageRoot,
      storePeer,
      $expectedCount,
      if backfillEnabled: "enabled" else: "disabled",
    ],
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

proc waitForHint(job: Job): Future[Timestamp] {.async.} =
  ## The stored hint, once the first write has landed.
  for _ in 0 ..< 50:
    let stored = (await job.readRecoveryHint()).expect("read record")
    if stored.isSome():
      return stored.get()
    await sleepAsync(100.milliseconds)
  raiseAssert "no recovery hint was stored in time"

proc waitForAdvance(
    job: Job, past: Timestamp, within = 15.seconds
): Future[Timestamp] {.async.} =
  ## The stored hint, once it has moved past `past`. A catch-up that learns
  ## its Store peer after subscribing waits out one retry period first.
  let deadline = Moment.now() + within
  while Moment.now() < deadline:
    let stored = (await job.readRecoveryHint()).expect("read record")
    if stored.isSome() and stored.get() > past:
      return stored.get()
    await sleepAsync(100.milliseconds)
  raiseAssert "the recovery hint did not advance in time"

proc knowStorePeer(net: TestNetwork) =
  ## Registers the store node as a service peer. The Store client dials it on demand.
  net.subscriber.waku.node.peerManager.addServicePeer(
    net.storeNodePeerInfo, WakuStoreCodec
  )

proc joinMesh(net: TestNetwork) {.async.} =
  ## Connects the subscriber to the store node and waits until they share a
  ## relay mesh, so a message the publisher relays reaches the subscriber live.
  ## Polls the mesh: the Store dial may have connected them already.
  await net.subscriber.waku.node.connectToNodes(@[net.storeNodePeerInfo])
  for _ in 0 ..< 100:
    if net.subscriber.waku.node.wakuRelay.getNumPeersInMesh(TestShard).valueOr(0) > 0:
      return
    await sleepAsync(100.milliseconds)
  raiseAssert "the subscriber did not join the relay mesh in time"

proc tunnel(net: TestNetwork, topic: ContentTopic): Future[WakuMessage] {.async.} =
  ## Disconnects the subscriber from the store node, waits until it reports
  ## `Disconnected`, then puts one message straight into the archive. Direct
  ## insertion keeps Store the only path; relay's cache can hand a published
  ## message over at reconnection.
  let offline = waitForConnectionStatus(
    net.subscriber.waku.brokerCtx, ConnectionStatus.Disconnected
  )
  await net.subscriber.waku.node.disconnectNode(net.storeNodePeerInfo)
  await offline
  let msg = WakuMessage(
    payload: "archived in the tunnel".toBytes(), contentTopic: topic, timestamp: now()
  )
  await net.storeNode.wakuArchive.handleMessage(TestShard, msg)
  await net.waitForArchived(topic, 2)
  return msg

proc publishLive(net: TestNetwork, topic: ContentTopic, text: string) {.async.} =
  ## A message the subscriber receives live, through the relay mesh.
  let msg = WakuMessage(payload: text.toBytes(), contentTopic: topic, timestamp: now())
  discard (await net.publisher.publish(Opt.some(TestShard), msg)).expect("publish live")

proc bringOnline(net: TestNetwork) {.async.} =
  ## Connects the subscriber to the store node and waits for the status event.
  let onlineFut = waitForConnectionStatus(
    net.subscriber.waku.brokerCtx, ConnectionStatus.PartiallyConnected
  )
  await net.subscriber.waku.node.connectToNodes(@[net.storeNodePeerInfo])
  await onlineFut

## Few multi-phase cases. Each `test` block costs three GC-tracked globals, and
## the refc runtime caps the waku test binary at 3500.

suite "Messaging API, Receive Service (store recovery)":
  asyncTest "a new process recovers what was archived while it was down":
    # Phase 1: the first session is stopped before its catch-up settles, so the
    # stored hint is its seed. The next process recovers the setup message and
    # all messages archived while stopped, across two Store pages.
    block:
      let root = createTempDir("recv-api-process-", "")
      defer:
        removeDir(root)
      let net = await setupNetwork(RestartTopic, root)
      defer:
        await net.teardown()
      (await net.subscriber.stop()).expect("stop previous session")
      net.subscriber = nil
      await net.archiveOffline()
      # Separates these messages from the child's start time.
      await sleepAsync(1.seconds)
      await net.runRestartedProcess(root, OfflineCount + 1)

    # Phase 2: disabled, only the reconnection check runs, and its `DelayExtra`
    # lookback is waited out first, so the child retrieves nothing. The saved
    # timestamp stays for a later run.
    block:
      let root = createTempDir("recv-api-disabled-", "")
      defer:
        removeDir(root)
      let net = await setupNetwork(RestartTopic, root)
      defer:
        await net.teardown()
      (await net.subscriber.stop()).expect("stop previous session")
      net.subscriber = nil
      await net.archiveOffline()
      await sleepAsync(DelayExtra + 1.seconds)
      await net.runRestartedProcess(root, 0, backfillEnabled = false)
      await net.runRestartedProcess(root, OfflineCount + 1)

    # Phase 3: on a first run the startup task seeds the recovery hint with the
    # service start, no later than the first subscription, so the next run
    # catches up from there.
    block:
      let root = createTempDir("recv-api-late-", "")
      defer:
        removeDir(root)
      var conf = createApiNodeConf()
      conf.localStoragePath = root
      var node: LogosDelivery
      lockNewGlobalBrokerContext:
        node = (await LogosDelivery.new(nodeConf(conf, backfillOverrides()))).expect(
          "create node"
        )
        (await node.start()).expect("start node")
      let topic = ContentTopic("/waku/2/recv-late-subscribe/proto")
      let subscribedAt = now()
      (await node.messagingClient.subscribe(topic)).expect("subscribe")
      let persistency = Persistency.new(root).expect("open root")
      defer:
        persistency.close()
      let job = persistency.openJob(MessagingJobId).expect("open job")
      check (await job.waitForHint()) <= subscribedAt
      (await node.stop()).expect("stop node")

    # Phase 4: the hint stays at the service start while nobody can be asked.
    # Once a Store peer is known, the startup catch-up completes and writes the
    # hint: one retry period until it asks again, one settle period after.
    block:
      let root = createTempDir("recv-api-advance-", "")
      defer:
        removeDir(root)
      let topic = ContentTopic("/waku/2/recv-advance/proto")
      let net = await setupNetwork(topic, root, knowStorePeer = false)
      defer:
        await net.teardown()
      let persistency = Persistency.new(root).expect("open root")
      defer:
        persistency.close()
      let job = persistency.openJob(MessagingJobId).expect("open job")
      let atStart = await job.waitForHint()
      await sleepAsync(1500.milliseconds)
      check (await job.readRecoveryHint()).expect("read record") == Opt.some(atStart)
      net.knowStorePeer()
      let cutoff = await job.waitForAdvance(
        atStart, within = CatchUpRetryPeriod + CatchUpSettlePeriod + 15.seconds
      )
      check cutoff < now()

    # Phase 5: after the startup catch-up exits, a received message advances
    # the hint to its receipt time, at most once per `ActivityWriteInterval`.
    block:
      let root = createTempDir("recv-api-live-", "")
      defer:
        removeDir(root)
      let topic = ContentTopic("/waku/2/recv-live/proto")
      let net = await setupNetwork(topic, root)
      defer:
        await net.teardown()
      let events = net.events
      let persistency = Persistency.new(root).expect("open root")
      defer:
        persistency.close()
      let job = persistency.openJob(MessagingJobId).expect("open job")
      await net.subscriber.messagingClient.recvService.waitForStartupCatchUp()
      check await events.waitForEvents(TestTimeout) # the setup message
      # The setup message was stamped after the seed and before the first
      # Store attempt, so the first value past it is the completion write.
      let cutoff = await job.waitForAdvance(events.receivedMessages[0].timestamp)
      check cutoff <= now()
      await net.joinMesh()
      events.targetCount = 2
      events.receivedEvent.clear()
      let beforeLive = now()
      await net.publishLive(topic, "live one")
      check await events.waitForEvents(TestTimeout)
      let afterFirst = await job.waitForAdvance(cutoff)
      check afterFirst >= beforeLive
      # A second message inside the interval leaves the hint as is.
      events.targetCount = 3
      events.receivedEvent.clear()
      await net.publishLive(topic, "live two")
      check await events.waitForEvents(TestTimeout)
      await sleepAsync(1500.milliseconds)
      check (await job.readRecoveryHint()).expect("read record") == Opt.some(afterFirst)
      # After the interval the next one writes again.
      await sleepAsync(ActivityWriteInterval)
      events.targetCount = 4
      events.receivedEvent.clear()
      await net.publishLive(topic, "live three")
      check await events.waitForEvents(TestTimeout)
      discard await job.waitForAdvance(afterFirst)

  asyncTest "recv_service recovers a missed message through a known Store peer":
    # Phase 1: the startup catch-up dials the known Store peer.
    block:
      let net = await setupNetwork(ContentTopic("/waku/2/recv-test/proto"))
      defer:
        await net.teardown()
      let eventManager = net.events
      check await eventManager.waitForEvents(TestTimeout)
      check eventManager.receivedMessages.len == 1
      if eventManager.receivedMessages.len > 0:
        check eventManager.receivedMessages[0].payload == net.missedPayload

    # Phase 2: a Store peer learned after the subscription, by connecting to
    # it, is asked as soon as the connection is reported.
    block:
      let net = await setupNetwork(
        ContentTopic("/waku/2/recv-learned-peer-test/proto"), knowStorePeer = false
      )
      defer:
        await net.teardown()
      let eventManager = net.events
      await net.bringOnline()
      check await eventManager.waitForEvents(TestTimeout)
      check eventManager.receivedMessages.len == 1
      if eventManager.receivedMessages.len > 0:
        check eventManager.receivedMessages[0].payload == net.missedPayload

    # Phase 3: storage closed under a running node ends the startup catch-up
    # with a warning once the connection wakes it. The node keeps running; the
    # reconnection check still delivers on its own.
    block:
      let net = await setupNetwork(
        ContentTopic("/waku/2/recv-storage-lost/proto"), knowStorePeer = false
      )
      defer:
        await net.teardown()
      GetPersistency
        .request(net.subscriber.waku.brokerCtx)
        .expect("persistency")
        .closeJob(MessagingJobId)
      await net.bringOnline()
      await net.subscriber.messagingClient.recvService.waitForStartupCatchUp()
      check net.subscriber.isRunning()

    # Phase 4: the hot path. After the startup catch-up, the reconnection
    # check recovers a message archived during a tunnel (offline, then
    # online).
    block:
      let topic = ContentTopic("/waku/2/recv-tunnel-test/proto")
      let net = await setupNetwork(topic)
      defer:
        await net.teardown()
      let eventManager = net.events
      check await eventManager.waitForEvents(TestTimeout) # the setup message
      await net.joinMesh() # the Store dial may already have connected them
      let gapMsg = await net.tunnel(topic)
      eventManager.targetCount = 2
      eventManager.receivedEvent.clear()
      await net.subscriber.waku.node.connectToNodes(@[net.storeNodePeerInfo])
      check await eventManager.waitForEvents(TestTimeout)
      check eventManager.receivedMessages.len == 2 and
        eventManager.receivedMessages[^1].payload == gapMsg.payload

  asyncTest "a topic subscribed while the catch-up settles is caught up to its own time":
    ## The app restores its subscriptions one call at a time. After the first
    ## topic is caught up, the worker waits `CatchUpSettlePeriod` for another;
    ## a topic subscribed in that window is caught up to its own pass, so a
    ## message archived after the first pass and before the subscription is
    ## delivered. Silence ends the worker; a topic subscribed after that gets
    ## live delivery only.
    let topicA = ContentTopic("/waku/2/recv-settle-a/proto")
    let topicB = ContentTopic("/waku/2/recv-settle-b/proto")
    let topicC = ContentTopic("/waku/2/recv-settle-c/proto")
    let net = await setupNetwork(topicA)
    defer:
      await net.teardown()
    let events = net.events
    check await events.waitForEvents(TestTimeout) # topic A, the setup message

    # Phase 1: archived after A's pass, before B's subscription.
    let msgB = WakuMessage(
      payload: "archived before B subscribed".toBytes(),
      contentTopic: topicB,
      timestamp: now(),
    )
    await net.storeNode.wakuArchive.handleMessage(TestShard, msgB) # inserted on return
    events.targetCount = 2
    events.receivedEvent.clear()
    (await net.subscriber.messagingClient.subscribe(topicB)).expect("subscribe B")
    check await events.waitForEvents(TestTimeout)
    check events.receivedMessages.len == 2 and
      events.receivedMessages[^1].payload == msgB.payload

    # Subscribing a topic that is already subscribed announces nothing, so a
    # send, which subscribes its topic every time, leaves the settle wait alone.
    var announced = 0
    let onSubscribed = proc(
        event: ContentTopicSubscribedEvent
    ) {.async: (raises: []).} =
      inc announced
    let announcements = ContentTopicSubscribedEvent
      .listen(net.subscriber.waku.brokerCtx, onSubscribed)
      .expect("listen")
    (await net.subscriber.messagingClient.subscribe(topicB)).expect("subscribe B again")
    await sleepAsync(200.milliseconds)
    await ContentTopicSubscribedEvent.dropListener(
      net.subscriber.waku.brokerCtx, announcements
    )
    check announced == 0

    # Phase 2: no further subscription within the period; the worker exits.
    await net.subscriber.messagingClient.recvService.waitForStartupCatchUp()
    let msgC = WakuMessage(
      payload: "archived before C subscribed".toBytes(),
      contentTopic: topicC,
      timestamp: now(),
    )
    await net.storeNode.wakuArchive.handleMessage(TestShard, msgC)
    events.targetCount = 3
    events.receivedEvent.clear()
    (await net.subscriber.messagingClient.subscribe(topicC)).expect("subscribe C")
    check not (await events.waitForEvents(3.seconds))
    check events.receivedMessages.len == 2

  asyncTest "the node drops an unsubscribed topic, live and from Store":
    ## The startup catch-up has exited. A new subscription in this run receives
    ## live messages only; the next start reaches the gap when the shared hint
    ## is behind it.
    let topic = ContentTopic("/waku/2/recv-resubscribe-test/proto")
    let net = await setupNetwork(topic)
    defer:
      await net.teardown()
    let eventManager = net.events

    await net.subscriber.messagingClient.recvService.waitForStartupCatchUp()
    check await eventManager.waitForEvents(TestTimeout)
    check eventManager.receivedMessages.len == 1

    net.subscriber.messagingClient.unsubscribe(topic).expect("unsubscribe")
    let archivedMsg = WakuMessage(
      payload: "archived while unsubscribed".toBytes(),
      contentTopic: topic,
      timestamp: now(),
    )
    discard (await net.publisher.publish(Opt.some(TestShard), archivedMsg)).expect(
      "publish while unsubscribed"
    )
    await net.waitForArchived(topic, 2)
    # Unsubscribed: dropped live, skipped in Store.
    check eventManager.receivedMessages.len == 1

    eventManager.targetCount = 2
    eventManager.receivedEvent.clear()
    (await net.subscriber.messagingClient.subscribe(topic)).expect("resubscribe")
    await net.subscriber.messagingClient.recvService.waitForStartupCatchUp()
    check not (await eventManager.waitForEvents(3.seconds))
    check eventManager.receivedMessages.len == 1

  asyncTest "messaging runs without durable storage":
    ## Phase 1: a started node with `:memory:` keeps the hint in memory. The
    ## catch-up waits for a Store peer; stop cancels it.
    block:
      var node: LogosDelivery
      lockNewGlobalBrokerContext:
        node = (await LogosDelivery.new(createApiNodeConf())).expect("create node")
        (await node.start()).expect("start node")
      check GetPersistency.request(node.waku.brokerCtx).isOk()
      let topic = ContentTopic("/waku/2/recv-memory-only/proto")
      (await node.messagingClient.subscribe(topic)).expect("subscribe")
      await sleepAsync(1500.milliseconds)
      check node.isRunning()
      (await node.stop()).expect("stop node")
      check not node.isRunning()
    ## Phase 2: no Persistency provider (transport not started). Messaging
    ## starts. Catch-up is suspended with a warning.
    block:
      var node: LogosDelivery
      lockNewGlobalBrokerContext:
        node = (await LogosDelivery.new(createApiNodeConf())).expect("create node")
      check GetPersistency.request(node.waku.brokerCtx).isErr()
      check node.messagingClient.start().isOk()
      (
        await node.messagingClient.subscribe(
          ContentTopic("/waku/2/recv-no-provider/proto")
        )
      ).expect("subscribe")
      await node.messagingClient.recvService.waitForStartupCatchUp()
      await sleepAsync(1500.milliseconds)
      check node.isRunning()
      await node.messagingClient.stop()
      check not node.isRunning()
    ## Phase 3: an out-of-range catch-up setting fails node creation. The
    ## full range checks are in the unit test.
    let bad = MessagingClientConf(backfillRequestTimeoutSeconds: Opt.some(0'i64))
    lockNewGlobalBrokerContext:
      check (await LogosDelivery.new(nodeConf(createApiNodeConf(), bad))).isErr()
    ## Phase 4: a job whose file path is a directory suspends catch-up with a
    ## warning. The node keeps running.
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
        (await node.start()).expect("start node")
      (await node.messagingClient.subscribe(ContentTopic("/waku/2/recv-bad-job/proto"))).expect(
        "subscribe"
      )
      await node.messagingClient.recvService.waitForStartupCatchUp()
      check node.isRunning()
      (await node.stop()).expect("stop node")
