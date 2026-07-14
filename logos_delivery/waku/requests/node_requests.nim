import results, brokers/[request_broker, multi_request_broker]
import logos_delivery/waku/waku_core/[topics]

RequestBroker(sync):
  type RequestRelayShard* = object
    relayShard*: RelayShard

  proc signature(
    pubsubTopic: Opt[PubsubTopic], contentTopic: ContentTopic
  ): Result[RequestRelayShard, string]
