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
    ## Set when the task first passes rate-limit admission; `none` while parked
    ## waiting for epoch budget. Guards re-admission on retry and anchors the
    ## delivery-timeout reaper, so a task parked for budget is not aged out
    ## before it can be sent.
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
    debug "RequestRelayShard.request failed", error = error
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
    return r.isNil() or r.msgHash == l.msgHash
  else:
    return false

proc messageAge*(self: DeliveryTask): timer.Duration =
  let actual = getNanosecondTime(getTime().toUnixFloat())
  if self.msg.timestamp >= 0 and self.msg.timestamp < actual:
    return nanoseconds(actual - self.msg.timestamp)
  else:
    return ZeroDuration

proc deliveryAge*(self: DeliveryTask): timer.Duration =
  if self.state == DeliveryState.SuccessfullyPropagated:
    return timer.Moment.now() - self.deliveryTime
  else:
    return ZeroDuration

proc propagationAge*(self: DeliveryTask): timer.Duration =
  ## Time elapsed since the message was first successfully propagated.
  ## Stable across re-publishes; ZeroDuration until first propagation.
  if self.firstPropagatedTime.isSome():
    return timer.Moment.now() - self.firstPropagatedTime.get()
  else:
    return ZeroDuration

proc admissionAge*(self: DeliveryTask): timer.Duration =
  ## Time since the task first passed admission; ZeroDuration while never
  ## admitted (still parked waiting for epoch budget).
  if self.firstAdmittedTime.isSome():
    return timer.Moment.now() - self.firstAdmittedTime.get()
  else:
    return ZeroDuration

proc isDeliveryTimedOut*(self: DeliveryTask, maxTime: timer.Duration): bool =
  ## True when an admitted task has been trying to deliver longer than `maxTime`
  ## without ever propagating. A task never admitted (parked for budget) is
  ## exempt: the clock runs from admission time, so waiting for budget does not count
  ## against it.
  return
    self.firstAdmittedTime.isSome() and self.firstPropagatedTime.isNone() and
    self.admissionAge() > maxTime

proc isEphemeral*(self: DeliveryTask): bool =
  return self.msg.ephemeral
