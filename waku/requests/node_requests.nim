import std/options
import brokers/[request_broker, multi_request_broker]
import waku/waku_core/[topics]

RequestBroker(sync):
  type RequestRelayShard* = object
    relayShard*: RelayShard

  proc signature(
    pubsubTopic: Option[PubsubTopic], contentTopic: ContentTopic
  ): Result[RequestRelayShard, string]
