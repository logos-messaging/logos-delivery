import std/[options, times], chronos
import waku/waku_core, waku/api/types, waku/requests/node_requests

type DeliveryState* {.pure.} = enum
  Entry
  SuccessfullyPropagated
  SuccessfullyValidated
  FallbackRetry
  NextRoundRetry
  FailedToDeliver

type DeliveryTask* = ref object
  requestId*: RequestId
  pubsubTopic*: PubsubTopic
  msg*: WakuMessage
  msgHash*: WakuMessageHash
  tryCount*: int
  state*: DeliveryState
  deliveryTime*: Moment
  errorDesc*: string

proc create*(
    T: type DeliveryTask, requestId: RequestId, envelop: MessageEnvelope
): Result[T, string] =
  let msg = envelop.toWakuMessage()
  # TODO: use sync request for such as soon as available
  let relayShardRes = (
    waitFor RequestRelayShard.request(none[PubsubTopic](), envelop.contentTopic)
  ).valueOr:
    return err($error)

  let pubsubTopic = relayShardRes.relayShard.toPubsubTopic()
  let msgHash = computeMessageHash(pubsubTopic, msg)

  return ok(
    T(
      requestId: requestId,
      pubsubTopic: pubsubTopic,
      msg: msg,
      msgHash: msgHash,
      tryCount: 0,
      state: DeliveryState.Entry,
    )
  )

func `==`*(r, l: DeliveryTask): bool =
  if r.isNil() == l.isNil():
    r.isNil() or r.msgHash == l.msgHash
  else:
    false

proc messageAge*(self: DeliveryTask): timer.Duration =
  let actual = getNanosecondTime(getTime().toUnixFloat())
  if self.msg.timestamp >= 0 and self.msg.timestamp < actual:
    nanoseconds(actual - self.msg.timestamp)
  else:
    ZeroDuration

proc deliveryAge*(self: DeliveryTask): timer.Duration =
  if self.state == DeliveryState.SuccessfullyPropagated:
    timer.Moment.now() - self.deliveryTime
  else:
    ZeroDuration

proc isEphemeral*(self: DeliveryTask): bool =
  return self.msg.ephemeral
