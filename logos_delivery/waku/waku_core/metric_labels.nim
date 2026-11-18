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

func enumLabel*[E: enum](value: E): string =
  ## A decoded enum can hold a value outside its declared ones.
  for known in E:
    if value == known:
      return $known
  return OtherLabel

const KnownDialSources = ["api", "static", "store", "dynamic bootstrap"]

func dialSourceLabel*(source: string): string =
  if source in KnownDialSources:
    return source
  return OtherLabel

func clusterLabel*(ours, cluster: uint16): string =
  ## Peers pick their cluster id: only ours gets its own label.
  if cluster == ours:
    return $cluster
  return OtherLabel

type TopicLabels* = object
  ## The pubsub topics of the shards a node is configured with, fixed at
  ## startup. Empty until set, which maps every topic to `OtherLabel`.
  clusterId: uint16
  topics: HashSet[PubsubTopic]

func init*(T: type TopicLabels, clusterId: uint16, shards: openArray[uint16]): T =
  var topics = initHashSet[PubsubTopic]()
  for shard in shards:
    topics.incl($RelayShard(clusterId: clusterId, shardId: shard))
  return TopicLabels(clusterId: clusterId, topics: topics)

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

func shardIdLabel*(labels: TopicLabels, shard: uint16): string =
  return labels.shardLabel($RelayShard(clusterId: labels.clusterId, shardId: shard))

{.pop.}
