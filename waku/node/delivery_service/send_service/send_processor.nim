import chronos
import ./delivery_task
import waku/common/broker/broker_context

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

  if task.state == DeliveryState.FallbackRetry:
    task.state = DeliveryState.NextRoundRetry
