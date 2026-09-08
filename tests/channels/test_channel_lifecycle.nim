{.used.}

import results, chronos, testutils/unittests
import brokers/broker_context

import ../testlib/[common, testasync]

import logos_delivery/api/conf/channels_conf
import logos_delivery/api/messaging_client_api
import logos_delivery/channels/reliable_channel_manager
import logos_delivery/channels/api/channel_lifecycle
import logos_delivery/channels/encryption/noop_encryption

suite "Reliable Channel - lifecycle":
  asyncTest "channelExists tracks create and close":
    const
      channelId = ChannelId("lifecycle-channel")
      contentTopic = ContentTopic("/reliable-channel/test/proto")

    var manager: ReliableChannelManager
    lockNewGlobalBrokerContext:
      manager = ReliableChannelManager.new(ReliableChannelManagerConf()).expect(
          "ReliableChannelManager.new"
        )
      setNoopEncryption()

      check not manager.channelExists(channelId)

      discard manager
        .createReliableChannel(channelId, contentTopic, SdsParticipantID("local"))
        .expect("createReliableChannel")

      check manager.channelExists(channelId)

      ## An unrelated id must not be reported as existing.
      check not manager.channelExists(ChannelId("other-channel"))

      (await manager.closeChannel(channelId)).expect("closeChannel")

      check not manager.channelExists(channelId)

  asyncTest "create subscribes the content topic, close unsubscribes it":
    ## Close unsubscribes only when no other open channel shares the topic.
    const
      topic = ContentTopic("/reliable-channel/test/subscribe/proto")
      chnA = ChannelId("subscribe-channel-a")
      chnB = ChannelId("subscribe-channel-b")

    var subscribed: seq[ContentTopic]
    var unsubscribed: seq[ContentTopic]
    var manager: ReliableChannelManager
    lockNewGlobalBrokerContext:
      let brokerCtx = globalBrokerContext()
      manager = ReliableChannelManager.new(ReliableChannelManagerConf()).expect(
          "ReliableChannelManager.new"
        )
      setNoopEncryption()

      MessagingSubscribe
        .setProvider(
          brokerCtx,
          proc(contentTopic: ContentTopic): Result[void, string] =
            subscribed.add(contentTopic)
            ok(),
        )
        .expect("setProvider MessagingSubscribe")
      MessagingUnsubscribe
        .setProvider(
          brokerCtx,
          proc(contentTopic: ContentTopic): Result[void, string] =
            unsubscribed.add(contentTopic)
            ok(),
        )
        .expect("setProvider MessagingUnsubscribe")

      discard manager.createReliableChannel(chnA, topic, SdsParticipantID("a")).expect(
          "createReliableChannel a"
        )
      check subscribed == @[topic]

      discard manager.createReliableChannel(chnB, topic, SdsParticipantID("b")).expect(
          "createReliableChannel b"
        )

      ## chnB still uses the topic: closing chnA must not unsubscribe.
      (await manager.closeChannel(chnA)).expect("closeChannel a")
      check unsubscribed.len == 0

      (await manager.closeChannel(chnB)).expect("closeChannel b")
      check unsubscribed == @[topic]

  asyncTest "a rejected segmentation config fails create and rolls the subscribe back":
    ## `ReliableChannel.new` became fallible when segmentation started
    ## validating its config, so `createReliableChannel` has to undo the
    ## content-topic subscription it makes before constructing.
    const
      topic = ContentTopic("/reliable-channel/test/bad-config/proto")
      chnGood = ChannelId("bad-config-good")
      chnBad = ChannelId("bad-config-bad")

    ## Below the package's minimum segment size, so every create fails.
    let conf = ReliableChannelManagerConf(segmentationSegmentSizeBytes: Opt.some(64))

    var subscribed: seq[ContentTopic]
    var unsubscribed: seq[ContentTopic]
    var manager: ReliableChannelManager
    lockNewGlobalBrokerContext:
      let brokerCtx = globalBrokerContext()
      manager = ReliableChannelManager.new(conf).expect("ReliableChannelManager.new")
      setNoopEncryption()

      MessagingSubscribe
        .setProvider(
          brokerCtx,
          proc(contentTopic: ContentTopic): Result[void, string] =
            subscribed.add(contentTopic)
            ok(),
        )
        .expect("setProvider MessagingSubscribe")
      MessagingUnsubscribe
        .setProvider(
          brokerCtx,
          proc(contentTopic: ContentTopic): Result[void, string] =
            unsubscribed.add(contentTopic)
            ok(),
        )
        .expect("setProvider MessagingUnsubscribe")

      let res = manager.createReliableChannel(chnBad, topic, SdsParticipantID("bad"))
      check res.isErr()
      check not manager.channelExists(chnBad)
      check subscribed == @[topic]
      check unsubscribed == @[topic]

      ## With a healthy manager holding the topic, a later failed create must
      ## leave that subscription alone.
      var good: ReliableChannelManager
      good = ReliableChannelManager.new(ReliableChannelManagerConf()).expect(
          "ReliableChannelManager.new good"
        )
      discard good
        .createReliableChannel(chnGood, topic, SdsParticipantID("good"))
        .expect("createReliableChannel good")
      unsubscribed.setLen(0)
      check manager.createReliableChannel(chnBad, topic, SdsParticipantID("bad")).isErr()
      ## `manager` holds no channel on the topic, so it still unsubscribes;
      ## the guard only protects channels of the same manager.
      check unsubscribed == @[topic]

      (await good.closeChannel(chnGood)).expect("closeChannel good")
