{.used.}

import testutils/unittests
import logos_delivery/waku/waku_core/[codecs, metric_labels]

suite "Waku Core - Metric labels":
  test "topics outside the configured shards are labelled other":
    let labels = TopicLabels.init(1, [0'u16, 5])

    check:
      labels.topicLabel("/waku/2/rs/1/5") == "/waku/2/rs/1/5"
      labels.topicLabel("/waku/2/rs/1/6") == OtherLabel
      labels.topicLabel("/waku/2/rs/2/5") == OtherLabel
      labels.topicLabel("any text a peer sends") == OtherLabel
      labels.shardLabel("/waku/2/rs/1/5") == "5"
      labels.shardLabel("/waku/2/rs/9/5") == OtherLabel
      TopicLabels().topicLabel("/waku/2/rs/1/5") == OtherLabel
      labels.shardIdLabel(5) == "5"
      labels.shardIdLabel(6) == OtherLabel

  test "agents and codecs map to a known set":
    check:
      agentLabel("nwaku/v0.36.0-abc") == "nwaku"
      agentLabel("my-own-client/1.0") == OtherLabel
      codecLabel(WakuStoreCodec) == WakuStoreCodec
      codecLabel("/vac/waku/made-up/1.0.0") == OtherLabel

  test "enums, dial sources and clusters map to a known set":
    type Color = enum
      Red
      Green

    check:
      enumLabel(Green) == "Green"
      enumLabel(cast[Color](7)) == OtherLabel
      dialSourceLabel("static") == "static"
      dialSourceLabel("anything else") == OtherLabel
      clusterLabel(1, 1) == "1"
      clusterLabel(1, 42) == OtherLabel
