import results, chronos, libp2p/peerid
import brokers/broker_context
import
  logos_delivery/waku/waku_core,
  logos_delivery/api/types,
  logos_delivery/waku/requests/node_requests

type
  DeliveryState* {.pure.} = enum
    Entry
    SuccessfullyPropagated
      # message is known to be sent to the network but not yet validated
    SuccessfullyValidated
      # message is known to be stored at least on one store node, thus validated
    FailedToDeliver # final state of failed delivery

  DeliveryTask* = ref object
    pubsubTopic*: PubsubTopic
    msg*: WakuMessage
      ## It gets its RLN proof at the first attempt. A later attempt uses that
      ## proof, or a new one after a node refused it.
    msgHash*: WakuMessageHash
    tryCount*: int ## The attempts that gave the message to a transport.
    state*: DeliveryState
    firstPropagatedTime*: Opt[Moment]
      ## Anchors the archive wait before the first Store query (see
      ## `nextStoreValidationBatch`), and the validation window.
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
    confirmed*: bool ## A Store node reported the message.
    storeAnswer*: Future[void].Raising([CancelledError])
      ## Pending while an attempt or `send` waits for a Store node to report the
      ## message. The Store validation loop asks about such a task only.
    storeMissed*: bool
      ## A Store node answered without the message. Each later Store query for
      ## this task can ask each Store node.
    lightpushPeersTried*: seq[PeerId]
    charge*: Opt[uint64] ## The result of `RateLimitManager.admit` for this task.
    chargeUnused*: bool
      ## True while the charge paid for no transmission and for no RLN message id.
      ## Such a charge goes back to the budget when the task ends.
    proofRefused*: bool
      ## A node refused the RLN proof, so the next attempt makes a new one.
    relayValidated*: bool
      ## The relay of this node validated the message with its current proof.

proc new*(
    T: typedesc[DeliveryTask],
    envelop: MessageEnvelope,
    brokerCtx: BrokerContext,
    timestamp = getNowInNanosecondTime(),
): Result[T, string] =
  let msg = envelop.toWakuMessage(timestamp)
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

func awaitsStore*(task: DeliveryTask): bool =
  return not task.storeAnswer.isNil() and not task.storeAnswer.finished()
