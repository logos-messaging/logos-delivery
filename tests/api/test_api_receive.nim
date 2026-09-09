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
import logos_delivery/api/conf/logos_delivery_conf
from logos_delivery/waku/api/peer_manager import peerIdsByProtocol
from logos_delivery/waku/waku_store/common import WakuStoreCodec

import
  logos_delivery,
  logos_delivery/waku/[
    waku_node,
    waku_core,
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
  conf

proc backfillOverrides(enabled = true): MessagingClientConf =
  MessagingClientConf(backfillEnabled: Opt.some(enabled))

proc nodeConf(kernel: WakuNodeConf, messaging: MessagingClientConf): LogosDeliveryConf =
  LogosDeliveryConf(kernelConf: KernelConf(kernel), messagingConf: Opt.some(messaging))

type TestNetwork = ref object
  storeNode: WakuNode
  publisher: WakuNode
  subscriber: LogosDelivery
  storeNodePeerInfo: RemotePeerInfo
  missedPayload: seq[byte]
  ownedRoot: string ## temp storage root created here, removed at teardown

proc setupNetwork(
    testTopic: ContentTopic, storageRoot = ""
): Future[TestNetwork] {.async.} =
  ## A started subscriber on `testTopic`, not connected to the store, with a
  ## message in the store that it did not see live. Its history is on disk,
  ## because an in-memory root disables catch-up. With no root given, the
  ## helper creates a temporary one.
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

  # Subscribed before the publish and without peers. The subscriber does not
  # see the message live, so the message is inside the range to catch up.
  var subscriber: LogosDelivery
  lockNewGlobalBrokerContext:
    var conf = createApiNodeConf(numShards)
    conf.localStoragePath = root
    subscriber = (await LogosDelivery.new(nodeConf(conf, backfillOverrides()))).expect(
      "Failed to create subscriber"
    )
    (await subscriber.start()).expect("Failed to start subscriber")
  (await subscriber.messagingClient.subscribe(testTopic)).expect("Failed to subscribe")

  # publish while the subscriber is offline: the message reaches the archive but
  # the subscriber never sees it via live relay
  let missedPayload = "This message was missed".toBytes()
  let missedMsg = WakuMessage(
    payload: missedPayload, contentTopic: testTopic, version: 0, timestamp: now()
  )
  discard (await publisher.publish(Opt.some(shard), missedMsg)).expect(
    "Publish missed msg failed"
  )

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

  return TestNetwork(
    storeNode: storeNode,
    publisher: publisher,
    subscriber: subscriber,
    storeNodePeerInfo: storeNodePeerInfo,
    missedPayload: missedPayload,
    ownedRoot: ownedRoot,
  )

proc teardown(net: TestNetwork) {.async.} =
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
const OfflineCount = 105
  ## archived while no subscriber process runs. Spans two Store pages

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
  (await subscriber.messagingClient.subscribe(RestartTopic)).expect("resubscribe")
  await subscriber.waku.node.connectToNodes(@[parsePeerInfo(storePeer).get()])
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

proc waitForLastOnline(job: Job): Future[Timestamp] {.async.} =
  ## The stored timestamp, once the first write has landed.
  for _ in 0 ..< 50:
    let stored = (await job.readLastOnline()).expect("read record")
    if stored.isSome():
      return stored.get()
    await sleepAsync(100.milliseconds)
  raiseAssert "no last-online timestamp was stored in time"

proc waitForAdvance(job: Job, past: Timestamp): Future[Timestamp] {.async.} =
  ## The stored timestamp, once it has moved past `past`. A second advance
  ## waits out the 10 s write period, so the budget is 14 s.
  for _ in 0 ..< 140:
    let stored = (await job.readLastOnline()).expect("read record")
    if stored.isSome() and stored.get() > past:
      return stored.get()
    await sleepAsync(100.milliseconds)
  raiseAssert "the last-online timestamp did not advance in time"

proc archiveDuringOutage(
    net: TestNetwork, topic: ContentTopic
): Future[WakuMessage] {.async.} =
  ## Disconnects the subscriber from the Store node, waits until it reports
  ## `Disconnected`, then archives one message it cannot see live.
  let offline = waitForConnectionStatus(
    net.subscriber.waku.brokerCtx, ConnectionStatus.Disconnected
  )
  await net.subscriber.waku.node.disconnectNode(net.storeNodePeerInfo)
  await offline
  let gapMsg = WakuMessage(
    payload: "archived during the outage".toBytes(),
    contentTopic: topic,
    timestamp: now(),
  )
  discard (await net.publisher.publish(Opt.some(TestShard), gapMsg)).expect(
    "publish during the outage"
  )
  await net.waitForArchived(topic, 2)
  return gapMsg

proc stopStoreNode(net: TestNetwork) {.async.} =
  ## Stops the Store node and waits until the subscriber has no connected
  ## Store peer left.
  await net.storeNode.stop()
  net.storeNode = nil
  for _ in 0 ..< 100:
    let peers = (await net.subscriber.waku.peerIdsByProtocol(WakuStoreCodec)).expect(
      "connected store peers"
    )
    if peers.len == 0:
      return
    await sleepAsync(100.milliseconds)
  raiseAssert "the Store peer did not disconnect in time"

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
    # Phase 1: the first session did not reach a Store peer. The next process
    # recovers the setup message and all messages archived while stopped,
    # across two Store pages.
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
      # A child that resumes from its own start does not find these messages.
      await sleepAsync(1.seconds)
      await net.runRestartedProcess(root, OfflineCount + 1)

    # Phase 2: disabled, the child retrieves nothing. The saved timestamp
    # stays for a later run.
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
      await net.runRestartedProcess(root, 0, backfillEnabled = false)
      await net.runRestartedProcess(root, OfflineCount + 1)

    # Phase 3: the first tick of a first run stores the service start as the
    # last-online timestamp, no later than the first subscription, so the next
    # run catches up from there.
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
      let p = Persistency.new(root).expect("open root")
      defer:
        p.close()
      let job = p.openJob(BackfillJobId).expect("open job")
      check (await job.waitForLastOnline()) <= subscribedAt
      (await node.stop()).expect("stop node")

    # Phase 4: with a Store peer and every topic caught up, the timestamp
    # advances past the catch-up. It stays put while there is no Store peer.
    block:
      let root = createTempDir("recv-api-advance-", "")
      defer:
        removeDir(root)
      let topic = ContentTopic("/waku/2/recv-advance/proto")
      let net = await setupNetwork(topic, root)
      defer:
        await net.teardown()
      let p = Persistency.new(root).expect("open root")
      defer:
        p.close()
      let job = p.openJob(BackfillJobId).expect("open job")
      # Not connected yet: the catch-up cannot run, so the timestamp is the
      # service start and stays there.
      await net.subscriber.messagingClient.recvService.checkStore()
      let atStart = await job.waitForLastOnline()
      await sleepAsync(1500.milliseconds)
      check (await job.readLastOnline()).expect("read record") == Opt.some(atStart)
      # Once connected the catch-up completes and the tick writes the timestamp.
      await net.subscriber.waku.node.connectToNodes(@[net.storeNodePeerInfo])
      await net.subscriber.messagingClient.recvService.checkStore()
      discard await job.waitForAdvance(atStart)

    # Phase 5: the Store node goes away. The timestamp stays where it is,
    # through a full write period and across the stop. Otherwise an outage
    # would count as time online and the next start would skip it.
    block:
      let root = createTempDir("recv-api-outage-", "")
      defer:
        removeDir(root)
      let topic = ContentTopic("/waku/2/recv-outage/proto")
      let net = await setupNetwork(topic, root)
      defer:
        await net.teardown()
      let p = Persistency.new(root).expect("open root")
      defer:
        p.close()
      let job = p.openJob(BackfillJobId).expect("open job")
      let atStart = await job.waitForLastOnline()
      await net.subscriber.waku.node.connectToNodes(@[net.storeNodePeerInfo])
      await net.subscriber.messagingClient.recvService.checkStore()
      discard await job.waitForAdvance(atStart)
      await net.stopStoreNode()
      # A write begun just before the outage lands within its read-back poll.
      await sleepAsync(1.seconds)
      let frozen = (await job.readLastOnline()).expect("read record")
      await sleepAsync(LastOnlinePeriod + 2.seconds)
      check (await job.readLastOnline()).expect("read record") == frozen
      (await net.subscriber.stop()).expect("stop subscriber")
      net.subscriber = nil
      check (await job.readLastOnline()).expect("read record") == frozen

    # Phase 6: an outage while running. The timestamp waits, reconnecting runs
    # the catch-up again, and only after it recovered what was archived
    # meanwhile does the timestamp move on.
    block:
      let root = createTempDir("recv-api-reconnect-", "")
      defer:
        removeDir(root)
      let topic = ContentTopic("/waku/2/recv-reconnect-gap/proto")
      let net = await setupNetwork(topic, root)
      defer:
        await net.teardown()
      let events = newReceiveEventListenerManager(net.subscriber.waku.brokerCtx, 1)
      defer:
        await events.teardown()
      let p = Persistency.new(root).expect("open root")
      defer:
        p.close()
      let job = p.openJob(BackfillJobId).expect("open job")
      let atStart = await job.waitForLastOnline()
      await net.bringOnline()
      check await events.waitForEvents(TestTimeout) # the setup message
      let beforeOutage = await job.waitForAdvance(atStart)
      let gapMsg = await net.archiveDuringOutage(topic)
      await sleepAsync(1500.milliseconds) # a tick sees the outage
      check (await job.readLastOnline()).expect("read record") == Opt.some(beforeOutage)
      events.targetCount = 2
      events.receivedEvent.clear()
      await net.subscriber.waku.node.connectToNodes(@[net.storeNodePeerInfo])
      check await events.waitForEvents(TestTimeout)
      check events.receivedMessages.len == 2 and
        events.receivedMessages[^1].payload == gapMsg.payload
      discard await job.waitForAdvance(beforeOutage)

  asyncTest "recv_service recovers a missed message on an explicit check and after connecting":
    # Phase 1: an explicit checkStore() recovers a message archived before
    # the subscriber connected.
    block:
      let net = await setupNetwork(ContentTopic("/waku/2/recv-test/proto"))
      defer:
        await net.teardown()
      let eventManager =
        newReceiveEventListenerManager(net.subscriber.waku.brokerCtx, 1)
      defer:
        await eventManager.teardown()
      await net.subscriber.waku.node.connectToNodes(@[net.storeNodePeerInfo])
      await net.subscriber.messagingClient.recvService.checkStore()
      check await eventManager.waitForEvents(TestTimeout)
      check eventManager.receivedMessages.len == 1
      if eventManager.receivedMessages.len > 0:
        check eventManager.receivedMessages[0].payload == net.missedPayload

    # Phase 2: connecting runs a catch-up that recovers a message archived
    # while the node was offline.
    block:
      let net = await setupNetwork(ContentTopic("/waku/2/recv-reconnect-test/proto"))
      defer:
        await net.teardown()
      let eventManager =
        newReceiveEventListenerManager(net.subscriber.waku.brokerCtx, 1)
      defer:
        await eventManager.teardown()
      await net.bringOnline()
      check await eventManager.waitForEvents(TestTimeout)
      check eventManager.receivedMessages.len == 1
      if eventManager.receivedMessages.len > 0:
        check eventManager.receivedMessages[0].payload == net.missedPayload

    # Phase 3: storage closed under a running node suspends catch-up with a
    # warning. The node keeps running.
    block:
      let net = await setupNetwork(ContentTopic("/waku/2/recv-storage-lost/proto"))
      defer:
        await net.teardown()
      let eventManager =
        newReceiveEventListenerManager(net.subscriber.waku.brokerCtx, 1)
      defer:
        await eventManager.teardown()
      GetPersistency
        .request(net.subscriber.waku.brokerCtx)
        .expect("persistency")
        .closeJob(BackfillJobId)
      await net.subscriber.waku.node.connectToNodes(@[net.storeNodePeerInfo])
      await net.subscriber.messagingClient.recvService.checkStore()
      check not (await eventManager.waitForEvents(3.seconds))
      check net.subscriber.isRunning()

    # Phase 4: an explicit check while disconnected dials the Store peer the
    # node knows. The Store client connects on demand.
    block:
      let topic = ContentTopic("/waku/2/recv-dial-test/proto")
      let net = await setupNetwork(topic)
      defer:
        await net.teardown()
      let eventManager =
        newReceiveEventListenerManager(net.subscriber.waku.brokerCtx, 1)
      defer:
        await eventManager.teardown()
      await net.bringOnline()
      check await eventManager.waitForEvents(TestTimeout)
      let gapMsg = await net.archiveDuringOutage(topic)
      await sleepAsync(1500.milliseconds) # a tick sees the outage
      eventManager.targetCount = 2
      eventManager.receivedEvent.clear()
      await net.subscriber.messagingClient.recvService.checkStore()
      check await eventManager.waitForEvents(TestTimeout)
      check eventManager.receivedMessages.len == 2 and
        eventManager.receivedMessages[^1].payload == gapMsg.payload

  asyncTest "an unsubscribed topic is delivered neither live nor from Store":
    ## Subscribing again re-runs the catch-up from the last write. The message
    ## archived meanwhile was archived while the node was online, so the
    ## timestamp may already be past it; recovering it is timing. The node
    ## never delivers a third message.
    let topic = ContentTopic("/waku/2/recv-resubscribe-test/proto")
    let net = await setupNetwork(topic)
    defer:
      await net.teardown()
    let eventManager = newReceiveEventListenerManager(net.subscriber.waku.brokerCtx, 1)
    defer:
      await eventManager.teardown()

    await net.bringOnline()
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
    # The node delivers nothing for an unsubscribed topic, live or from Store.
    check eventManager.receivedMessages.len == 1

    eventManager.targetCount = 2
    eventManager.receivedEvent.clear()
    (await net.subscriber.messagingClient.subscribe(topic)).expect("resubscribe")
    await net.subscriber.messagingClient.recvService.checkStore()
    discard await eventManager.waitForEvents(3.seconds)
    check eventManager.receivedMessages.len <= 2
    for received in eventManager.receivedMessages:
      check received.payload == net.missedPayload or
        received.payload == archivedMsg.payload

  asyncTest "an in-memory storage root leaves messaging running with catch-up off":
    ## Phase 1: a started node with `:memory:` keeps no history. Catch-up is
    ## off (info). Live messaging and explicit checks do no harm.
    block:
      var node: LogosDelivery
      lockNewGlobalBrokerContext:
        node = (await LogosDelivery.new(createApiNodeConf())).expect("create node")
        (await node.start()).expect("start node")
      check GetPersistency.request(node.waku.brokerCtx).isOk()
      let topic = ContentTopic("/waku/2/recv-memory-only/proto")
      (await node.messagingClient.subscribe(topic)).expect("subscribe")
      await node.messagingClient.recvService.checkStore()
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
      await node.messagingClient.recvService.checkStore()
      await sleepAsync(1500.milliseconds)
      check node.isRunning()
      await node.messagingClient.stop()
      check not node.isRunning()
    ## Phase 3: an out-of-range catch-up setting fails node creation. The
    ## full range checks are in the unit test.
    let bad = MessagingClientConf(backfillRequestTimeoutSeconds: Opt.some(0'i64))
    lockNewGlobalBrokerContext:
      check (await LogosDelivery.new(nodeConf(createApiNodeConf(), bad))).isErr()
    ## Phase 4: a job that cannot be opened (a directory where its file goes)
    ## suspends catch-up with a warning. The node keeps running.
    block:
      let root = createTempDir("recv-api-badjob-", "")
      defer:
        removeDir(root)
      createDir(root / "messaging-recv.db")
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
      await node.messagingClient.recvService.checkStore()
      check node.isRunning()
      (await node.stop()).expect("stop node")
