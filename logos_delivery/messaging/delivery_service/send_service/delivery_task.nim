import results, chronos
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
  Fallback # the next processor of the chain sends the task
  FailedToDeliver # final state of failed delivery

type DeliveryTask* = ref object
  pubsubTopic*: PubsubTopic
  msg*: WakuMessage
  msgHash*: WakuMessageHash
    ## Set with the timestamp of `msg` when `send` makes the task, and never changed.
  tryCount*: int
  state*: DeliveryState
  firstPropagatedTime*: Opt[Moment]
    ## Set when the message propagates.
    ## Anchors the archive wait before the first Store query (see
    ## `nextStoreValidationBatch`).
  propagatedEventEmitted*: bool
  anonymized*: bool
    ## Set at the first anonymous send attempt and never cleared; from then on,
    ## the INFO and ERROR records of this task withhold the hash.
  propagatedAnonymously*: bool
    ## Set when an anonymous path propagated the message. No store node confirms
    ## it: the query would name the message from this node's own address.
  lastStoreQueryTime*: Opt[Moment]
    ## When a Store peer was last asked about this task, none before the first query.
  deliverHandle*: Future[void]
    ## The `deliver` of the send service for this task. Nil or finished while
    ## it does not run.
  storeAnswer*: Future[void]
    ## Completes when a Store node reports the message. Nil while the send service
    ## does not wait for a Store confirmation of this task.
  storeMissed*: bool
    ## A Store node answered without the message. Each later Store query for
    ## this task can ask each Store node.
  charge*: Opt[uint64] ## The result of `RateLimitManager.admit` for this task.
  errorDesc*: string

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

proc isEphemeral*(self: DeliveryTask): bool =
  return self.msg.ephemeral
