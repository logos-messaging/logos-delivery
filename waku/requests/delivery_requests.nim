import waku/common/broker/request_broker
import waku/waku_core/topics

# Get the full interest list of the node
RequestBroker(sync):
  type RequestActiveSubscriptions* = object
    activeSubs*: seq[tuple[pubsubTopic: PubsubTopic, contentTopics: seq[ContentTopic]]]
