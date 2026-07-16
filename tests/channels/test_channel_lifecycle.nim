{.used.}

import chronos, testutils/unittests
import brokers/broker_context

import ../testlib/[common, testasync]

import logos_delivery/api/conf/channels_conf
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
