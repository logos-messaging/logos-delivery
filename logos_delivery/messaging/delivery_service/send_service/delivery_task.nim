import results, std/times, chronos
import brokers/broker_context
import
  logos_delivery/waku/waku_core,
  logos_delivery/api/types,
  logos_delivery/waku/requests/node_requests,
  ./delivery_plan

export delivery_plan, types

type StoreAnswer* = ref object
  ## The open Store wait of a task.
  ## The Store validation loop answers it, and `deliver` waits on it.
  signal: AsyncEvent
  missPending: bool ## A Store node answered without the message, until a step takes it.
  resend*: FutureBase ## The resend of this wait, nil before it starts.
  openedAt*: Moment
  deadline*: Moment ## The end of the Store validation window of the task.

type DeliveryTask* = ref object
  pubsubTopic*: PubsubTopic
  msg*: WakuMessage
  msgHash*: WakuMessageHash
  tryCount*: int
  state*: DeliveryState
    ## Only `move` changes it.
    ## A stop keeps the state of the cancelled step.
    ## A step that got its report before the cancel still moves the task.
  lastReport*: Opt[StepReport]
    ## The report that moved the task to its state, none before `deliver` starts.
    ## At a final state, it tells why the send ended.
  lastFailure*: Opt[Trigger]
    ## Why the last attempt of a round failed, none before a failure.
  firstPropagatedTime*: Opt[Moment]
    ## Set once on the first successful propagation; never reset on re-publish.
    ## Anchors the archive wait before the first Store query (see
    ## `nextStoreValidationBatch`).
  firstAdmittedTime*: Opt[Moment]
    ## Set when the task first passes rate-limit admission; `none` while parked
    ## waiting for epoch budget. Guards re-admission on retry and anchors the
    ## delivery window (`isDeliveryTimedOut`), so a task parked for budget is not
    ## aged out before it can be sent.
  propagatedEventEmitted*: bool ## Set when the task emits `MessagePropagatedEvent`.
  queuedEventEmitted*: bool
    ## Set once the task has reported itself queued for rate-limit budget, so
    ## the event fires on the first park only and not on every retry.
  anonymized*: bool
    ## Set at the first anonymous send attempt and never cleared; from then on,
    ## the INFO and ERROR records of this task withhold the hash.
  propagatedAnonymously*: bool
    ## Set when an anonymous path propagated the message. No store node confirms
    ## it: the query would name the message from this node's own address.
  lastStoreQueryTime*: Opt[Moment]
    ## When a Store peer was last asked about this task, none before the first query.
  storeValidationWaited*: timer.Duration
    ## The time that `deliver` waited for a Store confirmation of this task. A
    ## stop keeps it, so the validation window continues after a restart.
  deliverHandle*: Future[void]
    ## The `deliver` of the send service for this task. Nil or finished while
    ## it does not run.
  storeAnswer*: StoreAnswer
    ## Nil while `deliver` does not wait for a Store confirmation.
  storeReported*: bool
    ## A Store node reported the message before the end of the Store validation window.
    ## A stop keeps it, so the send ends at `Stored` after a restart.
  resendCount*: int
    ## How many times the send service sent the message again after a Store miss.
  proofRefreshes*: int ## How many times the send got a new RLN proof after a rejection.
  storeMissed*: bool
    ## A Store node answered without the message. Each later Store query for
    ## this task can ask each Store node.

proc new*(T: typedesc[StoreAnswer], openedAt, deadline: Moment): T =
  T(signal: newAsyncEvent(), openedAt: openedAt, deadline: deadline)

proc acceptStoreReport*(task: DeliveryTask, receivedAt: Moment) =
  ## Records a Store report whose response came before the Store window ended.
  ## The end is exclusive, as in `storeStep`.
  let answer = task.storeAnswer
  if answer.isNil() or receivedAt >= answer.deadline:
    return
  task.storeReported = true
  answer.signal.fire()

proc acceptStoreMiss*(task: DeliveryTask) =
  ## Records a Store miss for the next resend.
  ## A miss while a resend runs changes nothing.
  ## The query of such a miss usually started before the resend went out.
  ## A miss after a Store report changes nothing either.
  let answer = task.storeAnswer
  if answer.isNil() or task.storeReported:
    return
  if not answer.resend.isNil() and not answer.resend.finished():
    return
  answer.missPending = true
  answer.signal.fire()

func hasMiss*(answer: StoreAnswer): bool =
  answer.missPending

proc takeMiss*(answer: StoreAnswer): bool =
  ## True one time for each Store miss, so the plan gets the miss one time.
  let missed = answer.missPending
  answer.missPending = false
  return missed

proc clearSignal*(answer: StoreAnswer) =
  ## Clears the wake-up of the last answer, before a new wait.
  answer.signal.clear()

proc waitAnswer*(
    answer: StoreAnswer
): Future[void] {.async: (raises: [CancelledError]).} =
  ## Completes when the Store validation loop accepts an answer.
  ## Each call returns a new future.
  await answer.signal.wait()

proc new*(
    T: typedesc[DeliveryTask], envelop: MessageEnvelope, brokerCtx: BrokerContext
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

  return ok(T(pubsubTopic: pubsubTopic, msg: msg, msgHash: msgHash))

proc loggedHash*(task: DeliveryTask): string =
  ## The hash for INFO and ERROR records, withheld once the task is anonymized.
  if task.anonymized:
    "withheld"
  else:
    task.msgHash.to0xHex()

proc messageAge*(self: DeliveryTask): timer.Duration =
  let actual = getNanosecondTime(getTime().toUnixFloat())
  if self.msg.timestamp >= 0 and self.msg.timestamp < actual:
    return nanoseconds(actual - self.msg.timestamp)
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

proc isParkedExpired*(self: DeliveryTask, maxAge: timer.Duration): bool =
  ## True when a task never admitted (parked for budget) has outlived `maxAge`,
  ## measured from the message timestamp, so parking cannot grow the backlog
  ## and deliver arbitrarily late.
  return self.firstAdmittedTime.isNone() and self.messageAge() > maxAge

proc isEphemeral*(self: DeliveryTask): bool =
  return self.msg.ephemeral
