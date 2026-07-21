import results, std/times, chronos
import brokers/broker_context
import
  logos_delivery/waku/waku_core,
  logos_delivery/api/types,
  logos_delivery/waku/requests/node_requests

type DeliveryState* {.pure.} = enum
  Entry
  SuccessfullyPropagated
    # message is known to be sent to the network but not yet validated
  SuccessfullyValidated
    # message is known to be stored at least on one store node, thus validated
  FallbackRetry # retry sending with fallback processor if available
  NextRoundRetry # try sending in next loop
  FailedToDeliver # final state of failed delivery

type DeliveryTask* = ref object
  requestId*: RequestId
  pubsubTopic*: PubsubTopic
  msg*: WakuMessage
  msgHash*: WakuMessageHash
  tryCount*: int
  state*: DeliveryState
  deliveryTime*: Moment
  firstPropagatedTime*: Opt[Moment]
    ## Set once on the first successful propagation; never reset on re-publish.
    ## Anchors the store-validation time cap (see propagationAge).
  firstAdmittedTime*: Opt[Moment]
    ## Set when the task first passes rate-limit admission (consumes a budget
    ## slot / draws an RLN nonce); `none` while still parked waiting for epoch
    ## budget. Guards re-admission on retry and anchors the delivery-timeout
    ## reaper from the first real send attempt rather than message creation, so
    ## a task parked for budget is not aged out before it can be sent. Reset to
    ## `none` when an RLN rejection clears the proof, since regenerating draws a
    ## fresh nonce that must be re-admitted.
  propagateEventEmitted*: bool
  errorDesc*: string

proc new*(
    T: typedesc[DeliveryTask],
    requestId: RequestId,
    envelop: MessageEnvelope,
    brokerCtx: BrokerContext,
): Result[T, string] =
  let msg = envelop.toWakuMessage()
  # TODO: use sync request for such as soon as available
  let relayShardRes = (
    RequestRelayShard.request(brokerCtx, Opt.none(PubsubTopic), envelop.contentTopic)
  ).valueOr:
    error "RequestRelayShard.request failed", error = error
    return err("Failed create DeliveryTask: " & $error)

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

proc propagationAge*(self: DeliveryTask): timer.Duration =
  ## Time elapsed since the message was first successfully propagated.
  ## Stable across re-publishes; ZeroDuration until first propagation.
  if self.firstPropagatedTime.isSome():
    timer.Moment.now() - self.firstPropagatedTime.get()
  else:
    ZeroDuration

proc admissionAge*(self: DeliveryTask): timer.Duration =
  ## Time elapsed since the task first passed admission; ZeroDuration while it
  ## has never been admitted (i.e. still parked waiting for epoch budget).
  if self.firstAdmittedTime.isSome():
    timer.Moment.now() - self.firstAdmittedTime.get()
  else:
    ZeroDuration

proc isDeliveryTimedOut*(self: DeliveryTask, maxTime: timer.Duration): bool =
  ## True when the task was admitted (drew a slot) and has been trying to
  ## deliver longer than `maxTime` without ever propagating. A task never
  ## admitted — still parked waiting for epoch budget — is exempt: it is waiting
  ## for the epoch to roll, not failing to deliver, and the clock runs from
  ## admission, not message creation, so budget wait does not count against it.
  self.firstAdmittedTime.isSome() and self.firstPropagatedTime.isNone() and
    self.admissionAge() > maxTime

proc isEphemeral*(self: DeliveryTask): bool =
  return self.msg.ephemeral
