import brokers/request_broker
import logos_delivery/waku/waku_core/message/message
import logos_delivery/waku/rln/api/types as rln_api_types

export rln_api_types

RequestBroker:
  type RequestGenerateRlnProof* = object
    proof*: seq[byte]

  proc signature(
    message: WakuMessage, senderEpoch: float64
  ): Future[Result[RequestGenerateRlnProof, string]] {.async.}

RequestBroker:
  type RequestValidateRlnProof* = object
    validation*: ValidationResult

  proc signature(
    message: WakuMessage,
    registryId: RegistryId,
    rlnIdentifier: RlnIdentifier,
    timestamp: uint64,
  ): Future[Result[RequestValidateRlnProof, string]] {.async.}

RequestBroker:
  type RequestStartRlnModule* = object
    response*: string

  proc signature(): Future[Result[RequestStartRlnModule, string]] {.async.}

RequestBroker:
  type RequestRegisterRlnMembership* = object
    response*: string

  proc signature(
    registryId: RegistryId, rlnIdentifier: RlnIdentifier, options: RegistryOptions
  ): Future[Result[RequestRegisterRlnMembership, string]] {.async.}
