import brokers/request_broker
import logos_delivery/waku/waku_core/message/message
import logos_delivery/waku/rln/rln_lez/types as rln_api_types

export rln_api_types

RequestBroker:
  type RequestGenerateRlnProof* = object
    proof*: seq[byte]

  proc signature(
    message: WakuMessage, timestamp: uint64
  ): Future[Result[RequestGenerateRlnProof, string]] {.async.}

RequestBroker:
  type RequestValidateRlnProof* = object
    validation*: ValidationResult

  proc signature(
    message: WakuMessage, timestamp: uint64
  ): Future[Result[RequestValidateRlnProof, string]] {.async.}

RequestBroker:
  type RequestGetRlnMembershipState* = object
    state*: MembershipState

  proc signature(): Future[Result[RequestGetRlnMembershipState, string]] {.async.}
