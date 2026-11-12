## Maps values to the fixed set of Prometheus label values they may take, so
## that no metric grows one time series per value a peer or a caller picks.

{.push raises: [].}

import std/[sets, strutils], results
import ./codecs, ./topics/pubsub_topic

const OtherLabel* = "other" ## Label value of anything outside the known set.

const KnownAgents = [
  "nwaku", "logos-delivery", "go-waku", "js-waku", "nim-libp2p", "go-libp2p",
  "rust-libp2p", "js-libp2p",
]

func agentLabel*(agent: string): string =
  ## Remote peers choose their agent string freely.
  let lowered = agent.toLowerAscii()
  for known in KnownAgents:
    if known in lowered:
      return known
  return OtherLabel

func codecLabel*(codec: string): string =
  if codec in WakuCodecs:
    return codec
  return OtherLabel

type TopicLabels* = object
  ## The pubsub topics of the shards a node is configured with, fixed at
  ## startup. Empty until set, which maps every topic to `OtherLabel`.
  topics: HashSet[PubsubTopic]

func init*(T: type TopicLabels, clusterId: uint16, shards: openArray[uint16]): T =
  var topics = initHashSet[PubsubTopic]()
  for shard in shards:
    topics.incl($RelayShard(clusterId: clusterId, shardId: shard))
  return TopicLabels(topics: topics)

func topicLabel*(labels: TopicLabels, topic: PubsubTopic): string =
  if topic in labels.topics:
    return topic
  return OtherLabel

func shardLabel*(labels: TopicLabels, topic: PubsubTopic): string =
  ## The shard id of a configured topic.
  if topic notin labels.topics:
    return OtherLabel
  let shard = RelayShard.parseStaticSharding(topic).valueOr:
    return OtherLabel
  return $shard.shardId

{.pop.}
