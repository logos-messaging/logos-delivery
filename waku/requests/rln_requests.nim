import waku/common/broker/request_broker, waku/waku_core/message/message

RequestBroker:
  type RequestGenerateRlnProof* = object
    proof*: seq[byte]

  proc signature(
    message: WakuMessage, senderEpoch: float64
  ): Future[Result[RequestGenerateRlnProof, string]] {.async.}
