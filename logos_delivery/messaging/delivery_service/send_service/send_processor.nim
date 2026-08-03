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

proc parkForRlnProofRefresh*(task: DeliveryTask, waku: Waku) =
  ## The service refused the task's proof as RLN-invalid: the message itself is
  ## fine, its proof went stale against a moved merkle root. Schedules a
  ## background merkle-path refresh and clears the proof so the next round
  ## regenerates one against the refreshed path — `attachRlnProof`
  ## short-circuits on an existing proof, so without the clear the rejected
  ## bytes would be resent until age-out. Resetting admission re-charges the
  ## fresh nonce that regeneration draws.
  waku.onRlnProofRejected()
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
  # first send). Both must be queued for the next round so the service loop
  # retries them; otherwise the task would sit untouched until it ages out.
  if task.state == DeliveryState.FallbackRetry or task.state == DeliveryState.Entry:
    task.state = DeliveryState.NextRoundRetry
