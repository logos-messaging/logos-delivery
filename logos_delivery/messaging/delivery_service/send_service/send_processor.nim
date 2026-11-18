## A send processor runs the step of one transport state of the delivery plan.
## It makes one attempt and returns its report.

import results, chronos
import brokers/broker_context
import logos_delivery/waku/api/publish
import ./[delivery_task, delivery_plan]

{.push raises: [].}

type BaseSendProcessor* = ref object of RootObj
  brokerCtx*: BrokerContext

type SendProcessors* = object ## A nil field is a processor that the node does not have.
  mix*: BaseSendProcessor
  relay*: BaseSendProcessor
  lightpush*: BaseSendProcessor
  resender*: BaseSendProcessor ## Sends a message again after a Store miss.

method checkBeforeSend*(
    self: BaseSendProcessor, task: DeliveryTask
): Result[void, SendError] {.base, gcsafe, raises: [].} =
  ## Refuses a message that can never go out, before it takes a charge or a message id.
  ## Only a `Required` node asks, because mix is its only transport.
  return ok()

method checkBeforeAttempt*(
    self: BaseSendProcessor, task: DeliveryTask
): Result[void, StepReport] {.base, gcsafe, raises: [].} =
  ## Refuses an attempt that cannot work now, with no network call.
  return ok()

method attempt*(
    self: BaseSendProcessor, task: DeliveryTask
): Future[StepReport] {.async, base.} =
  raiseAssert "attempt is not implemented"

func transports*(processors: SendProcessors): set[DeliveryState] =
  var states: set[DeliveryState]
  if not processors.mix.isNil():
    states.incl(DeliveryState.Mix)
  if not processors.relay.isNil():
    states.incl(DeliveryState.Relay)
  if not processors.lightpush.isNil():
    states.incl(DeliveryState.Lightpush)
  return states

func processorOf*(processors: SendProcessors, state: DeliveryState): BaseSendProcessor =
  case state
  of DeliveryState.Mix: processors.mix
  of DeliveryState.Relay: processors.relay
  of DeliveryState.Lightpush: processors.lightpush
  of DeliveryState.StoreResend: processors.resender
  else: nil

func lightpushReport*(error: ErrorStatus): StepReport =
  ## Only the text tells an RLN rejection apart from another invalid message.
  let desc = error.desc.get($error.code)
  if error.isRlnRejection():
    return StepReport.init(Trigger.ProofRejected, desc)
  let trigger =
    case error.code
    of LightPushErrorCode.NO_PEERS_TO_RELAY: Trigger.ServiceNoRelayPeers
    of LightPushErrorCode.TOO_MANY_REQUESTS: Trigger.ServiceBusy
    of LightPushErrorCode.SERVICE_NOT_AVAILABLE: Trigger.ServiceUnavailable
    of LightPushErrorCode.INTERNAL_SERVER_ERROR: Trigger.ServiceError
    else: Trigger.Rejected
  return StepReport.init(trigger, desc)

func publishReport*(peers: uint32): StepReport =
  if peers > 0:
    StepReport.init(Trigger.Published)
  else:
    StepReport.init(Trigger.ZeroPeers)
