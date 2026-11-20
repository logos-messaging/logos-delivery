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
  NextRoundRetry # waits for its next attempt
  FailedToDeliver # final state of failed delivery

type DeliveryTask* = ref object
  pubsubTopic*: PubsubTopic
  msg*: WakuMessage
  msgHash*: WakuMessageHash
  tryCount*: int
  state*: DeliveryState
  firstPropagatedTime*: Opt[Moment]
    ## Set once on the first successful propagation; never reset on re-publish.
    ## Anchors the archive wait before the first Store query (see
    ## `nextStoreValidationBatch`).
  firstAdmittedTime*: Opt[Moment]
    ## Set when `send` charges the rate-limit budget. A rejected RLN proof clears
    ## it, so the new proof gets a new admission.
  admittedInEpoch*: Opt[uint64]
    ## The epoch, as `RateLimitManager` counts them, that `send` admitted the
    ## message in. It is the manager's own epoch serial (1, 2, 3…), not the RLN
    ## epoch index. `none` when the manager does not limit sends: the message was
    ## admitted and nothing was counted. A new RLN proof after a rejected one takes
    ## a new admission and replaces it.
  admissionRefundable*: bool
    ## True when `send` took one unit of the epoch budget for this message and
    ## the message has not used it yet: no RLN proof drew a message id for it,
    ## and no send attempt went out. If the task ends while this is true,
    ## `finish` returns the unit to the budget with `RateLimitManager.release`.

  propagatedEventEmitted*: bool
    ## Set when the task emits `MessagePropagatedEvent`. After a restart, the send
    ## service does not send the task again.
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
  storeAnswer*: Future[void]
    ## Completes when a Store node reports the message. Nil while the send service
    ## does not wait for a Store confirmation of this task.
  resendCount*: int
    ## How many times the send service sent the message again after a Store miss.
  storeMissed*: bool
    ## A Store node answered without the message. Each later Store query for
    ## this task can ask each Store node.
  errorDesc*: string

proc new*(
    T: typedesc[DeliveryTask],
    envelop: MessageEnvelope,
    brokerCtx: BrokerContext,
    timestamp: Timestamp,
): Result[T, string] =
  ## Stamps the message with `timestamp`. The timestamp, and so the hash, never
  ## changes after this.
  let msg = envelop.toWakuMessage(timestamp)
  # TODO: use sync request for such as soon as available
  let relayShardRes = (
    RequestRelayShard.request(brokerCtx, Opt.none(PubsubTopic), envelop.contentTopic)
  ).valueOr:
    debug "RequestRelayShard.request failed", error = error
    return err("failed to create DeliveryTask: " & $error)

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
  ## How far the message timestamp is from the clock of this node. A validator
  ## compares the same two values, so a timestamp ahead of the clock also counts.
  let actual = getNanosecondTime(getTime().toUnixFloat())
  return nanoseconds(abs(actual - self.msg.timestamp))

proc propagationAge*(self: DeliveryTask): timer.Duration =
  ## Time elapsed since the message was first successfully propagated.
  ## Stable across re-publishes; ZeroDuration until first propagation.
  if self.firstPropagatedTime.isSome():
    return timer.Moment.now() - self.firstPropagatedTime.get()
  else:
    return ZeroDuration

proc isDeliveryTimedOut*(self: DeliveryTask, window: timer.Duration): bool =
  ## True when the task did not propagate within `window` of its message
  ## timestamp. Store and RLN validators refuse a message far off their clock, so
  ## a later attempt would be refused anyway.
  return self.firstPropagatedTime.isNone() and self.messageAge() > window

proc isEphemeral*(self: DeliveryTask): bool =
  return self.msg.ephemeral
