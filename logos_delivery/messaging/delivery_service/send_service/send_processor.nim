import results, chronos
import brokers/broker_context
import logos_delivery/waku/waku, logos_delivery/waku/api/publish
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

method sendImpl*(
    self: BaseSendProcessor, task: DeliveryTask
): Future[void] {.async, base.} =
  assert false, "Not implemented"

method canResend*(self: BaseSendProcessor, task: DeliveryTask): bool {.base, gcsafe.} =
  ## True when this processor can send the task again after a Store miss.
  return false

method resendImpl*(
    self: BaseSendProcessor, task: DeliveryTask
): Future[void] {.async: (raises: [CancelledError]), base.} =
  ## Sends the task again. It logs each error and raises only `CancelledError`,
  ## as no caller reads a result.
  discard

proc resend*(
    self: BaseSendProcessor, task: DeliveryTask
) {.async: (raises: [CancelledError]).} =
  ## Sends the task again through the first processor of the chain that can.
  var currentProcessor: BaseSendProcessor = self
  while not currentProcessor.isNil():
    if currentProcessor.canResend(task):
      await currentProcessor.resendImpl(task)
      return
    currentProcessor = currentProcessor.fallbackProcessor

proc parkForRlnProofRefresh*(task: DeliveryTask, waku: Waku, errorDesc: string) =
  ## The service refused the task's proof as RLN-invalid: its proof went stale
  ## against a moved merkle root. Schedules a background merkle-path refresh and
  ## clears the proof so the next retry regenerates one against the refreshed
  ## path; `attachRlnProof` reuses an existing proof, so without the clear the
  ## rejected bytes would be resent. Resetting admission charges the new nonce
  ## the regenerated proof draws. Without a backend refresh hook a retry would
  ## be rejected the same way, so the task fails with `errorDesc`.
  if not waku.onRlnProofRejected():
    task.state = DeliveryState.FailedToDeliver
    task.errorDesc = errorDesc
    return
  task.msg.proof = @[]
  task.firstAdmittedTime = Opt.none(Moment)
  task.state = DeliveryState.NextRoundRetry

method process*(
    self: BaseSendProcessor, task: DeliveryTask
): Future[void] {.async, base.} =
  var currentProcessor: BaseSendProcessor = self
  var keepTrying = true
  while not currentProcessor.isNil() and keepTrying:
    if currentProcessor.isValidProcessor(task):
      await currentProcessor.sendImpl(task)
    currentProcessor = currentProcessor.fallbackProcessor
    keepTrying = task.state == DeliveryState.FallbackRetry

  # A task still in `FallbackRetry` exhausted the chain without delivering, and
  # one still in `Entry` was never attempted because no processor had a usable
  # peer yet (e.g. a lightpush peer that finishes registering right after the
  # first send). Both must wait for the next attempt.
  if task.state == DeliveryState.FallbackRetry or task.state == DeliveryState.Entry:
    task.state = DeliveryState.NextRoundRetry
