import results, chronos
import brokers/broker_context
import logos_delivery/waku/waku, logos_delivery/waku/api/publish
import logos_delivery/waku/waku_lightpush/common
import logos_delivery/api/types
import ./delivery_task

{.push raises: [].}

type BaseSendProcessor* = ref object of RootObj
  fallbackProcessor*: BaseSendProcessor
  brokerCtx*: BrokerContext

proc chain*(self: BaseSendProcessor, next: BaseSendProcessor) =
  self.fallbackProcessor = next

method isValidProcessor*(
    self: BaseSendProcessor, task: DeliveryTask
): bool {.base, gcsafe.} =
  return false

method checkBeforeAdmission*(
    self: BaseSendProcessor, task: DeliveryTask
): Result[void, SendError] {.base, gcsafe, raises: [].} =
  ## Returns the error of a task that `send` refuses before it spends budget.
  return ok()

method hasSendPeer*(
    self: BaseSendProcessor, task: DeliveryTask
): bool {.base, gcsafe, raises: [].} =
  return true

method noSendPeerReason*(
    self: BaseSendProcessor, task: DeliveryTask
): string {.base, gcsafe, raises: [].} =
  return ""

proc chainHasSendPeer*(self: BaseSendProcessor, task: DeliveryTask): bool =
  var currentProcessor: BaseSendProcessor = self
  while not currentProcessor.isNil():
    if currentProcessor.hasSendPeer(task):
      return true
    currentProcessor = currentProcessor.fallbackProcessor
  return false

method sendImpl*(
    self: BaseSendProcessor, task: DeliveryTask
): Future[void] {.async, base.} =
  assert false, "Not implemented"

const NoSendPeerReason* = "No peer accepted the message"

proc sendErrorDesc*(error: ErrorStatus): string =
  if error.desc.isSome():
    return error.desc.get()
  if error.code == LightPushErrorCode.NO_PEERS_TO_RELAY:
    return NoSendPeerReason
  return "Send failed with the lightpush status " & $error.code

proc failRlnRejected*(task: DeliveryTask, waku: Waku, errorDesc: string) =
  ## A service refused the RLN proof of the task.
  ## Starts a refresh of the merkle path in the background, for the next `send`.
  discard waku.onRlnProofRejected()
  task.state = DeliveryState.FailedToDeliver
  task.errorDesc = errorDesc

method process*(
    self: BaseSendProcessor, task: DeliveryTask
): Future[void] {.async, base.} =
  var currentProcessor: BaseSendProcessor = self
  var keepTrying = true
  while not currentProcessor.isNil() and keepTrying:
    if currentProcessor.isValidProcessor(task):
      await currentProcessor.sendImpl(task)
    currentProcessor = currentProcessor.fallbackProcessor
    keepTrying = task.state == DeliveryState.Fallback

  # A task still in `Fallback` got to the end of the chain.
  # A task still in `Entry` found no processor with a peer.
  if task.state == DeliveryState.Fallback or task.state == DeliveryState.Entry:
    task.state = DeliveryState.FailedToDeliver
    if task.errorDesc.len == 0:
      task.errorDesc = NoSendPeerReason
