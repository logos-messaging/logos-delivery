{.used.}

import std/[sequtils, sets, tables]
import chronos, results, testutils/unittests
import brokers/broker_context
import logos_delivery/waku/[waku_core, waku_node, node/subscription_manager]
import logos_delivery/waku/api/events/subscription_events
import ../testlib/[wakucore, wakunode, testasync]

const TestShard = PubsubTopic("/waku/2/rs/0/7")

suite "Shard subscription events":
  var node {.threadvar.}: WakuNode
  var subscribed {.threadvar.}: seq[PubsubTopic]
  var unsubscribed {.threadvar.}: seq[PubsubTopic]

  asyncSetup:
    subscribed = @[]
    unsubscribed = @[]
    node = newTestWakuNode(generateSecp256k1Key())
    (await node.mountRelay()).isOkOr:
      raiseAssert error

    let onSub = proc(
        ev: ShardSubscribedEvent
    ): Future[void] {.async: (raises: []), gcsafe.} =
      subscribed.add(ev.topic)
    discard ShardSubscribedEvent.listen(node.brokerCtx, onSub)

    let onUnsub = proc(
        ev: ShardUnsubscribedEvent
    ): Future[void] {.async: (raises: []), gcsafe.} =
      unsubscribed.add(ev.topic)
    discard ShardUnsubscribedEvent.listen(node.brokerCtx, onUnsub)

  asyncTeardown:
    await ShardSubscribedEvent.dropAllListeners(node.brokerCtx)
    await ShardUnsubscribedEvent.dropAllListeners(node.brokerCtx)
    await node.stop()

  asyncTest "relay subscribe and unsubscribe emit shard events":
    node.subscriptionManager.subscribeShard(TestShard).isOkOr:
      raiseAssert error
    await sleepAsync(chronos.milliseconds(10))

    check:
      subscribed == @[TestShard]
      unsubscribed.len == 0

    node.subscriptionManager.unsubscribeShard(TestShard).isOkOr:
      raiseAssert error
    await sleepAsync(chronos.milliseconds(10))

    check:
      unsubscribed == @[TestShard]

  asyncTest "re-subscribing an already subscribed shard emits once":
    node.subscriptionManager.subscribeShard(TestShard).isOkOr:
      raiseAssert error
    node.subscriptionManager.subscribeShard(TestShard).isOkOr:
      raiseAssert error
    await sleepAsync(chronos.milliseconds(10))

    check subscribed == @[TestShard]

suite "Weak content topic interest":
  const WeakTopic = ContentTopic("/weak-interest/1/weak/proto")
  const StrongTopic = ContentTopic("/weak-interest/1/strong/proto")
  var node {.threadvar.}: WakuNode

  asyncSetup:
    node = newTestWakuNode(generateSecp256k1Key())
    (await node.mountRelay()).isOkOr:
      raiseAssert error

  asyncTeardown:
    await node.stop()

  asyncTest "an app subscribe makes a weak interest strong, and a weak subscribe keeps a strong one":
    let manager = node.subscriptionManager
    manager.subscribe(TestShard, WeakTopic, weak = true).isOkOr:
      raiseAssert error
    check WeakTopic in manager.shards[TestShard].weakTopics

    manager.subscribe(TestShard, WeakTopic).isOkOr:
      raiseAssert error
    manager.subscribe(TestShard, StrongTopic).isOkOr:
      raiseAssert error
    manager.subscribe(TestShard, StrongTopic, weak = true).isOkOr:
      raiseAssert error

    check:
      manager.shards[TestShard].weakTopics.len == 0
      manager.isContentSubscribed(TestShard, WeakTopic)
      manager.isContentSubscribed(TestShard, StrongTopic)

  asyncTest "an unsubscribe removes the weak mark":
    let manager = node.subscriptionManager
    manager.subscribe(TestShard, StrongTopic).isOkOr: # keeps the shard entry
      raiseAssert error
    manager.subscribe(TestShard, WeakTopic, weak = true).isOkOr:
      raiseAssert error
    manager.unsubscribe(TestShard, WeakTopic).isOkOr:
      raiseAssert error
    manager.subscribe(TestShard, WeakTopic).isOkOr:
      raiseAssert error

    check WeakTopic notin manager.shards[TestShard].weakTopics
