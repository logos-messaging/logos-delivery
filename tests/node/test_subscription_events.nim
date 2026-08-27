{.used.}

import std/sequtils
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
