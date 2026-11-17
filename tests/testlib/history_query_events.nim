## Collects the history query events of one broker context.

import std/sequtils, chronos, results, stew/byteutils
import brokers/broker_context
import logos_delivery/api/events/messaging_client_events
import logos_delivery/waku/waku_core

type HistoryQueryEvents* = ref object
  ctx: BrokerContext
  messages*: seq[HistoryQueryMessageEvent]
  completed*: seq[HistoryQueryCompletedEvent]
  errors*: seq[HistoryQueryErrorEvent]
  finishedAt*: Timestamp ## the time of the last completed or error event
  finished: AsyncEvent
  messageListener: HistoryQueryMessageEventListener
  completedListener: HistoryQueryCompletedEventListener
  errorListener: HistoryQueryErrorEventListener

proc new*(T: type HistoryQueryEvents, ctx: BrokerContext): T =
  let events = HistoryQueryEvents(ctx: ctx, finished: newAsyncEvent())
  events.messageListener = HistoryQueryMessageEvent
    .listen(
      ctx,
      proc(event: HistoryQueryMessageEvent) {.async: (raises: []).} =
        events.messages.add(event),
    )
    .expect("listen to HistoryQueryMessageEvent")
  events.completedListener = HistoryQueryCompletedEvent
    .listen(
      ctx,
      proc(event: HistoryQueryCompletedEvent) {.async: (raises: []).} =
        events.completed.add(event)
        events.finishedAt = getNowInNanosecondTime()
        events.finished.fire(),
    )
    .expect("listen to HistoryQueryCompletedEvent")
  events.errorListener = HistoryQueryErrorEvent
    .listen(
      ctx,
      proc(event: HistoryQueryErrorEvent) {.async: (raises: []).} =
        events.errors.add(event)
        events.finishedAt = getNowInNanosecondTime()
        events.finished.fire(),
    )
    .expect("listen to HistoryQueryErrorEvent")
  return events

proc reset*(events: HistoryQueryEvents) =
  events.messages = @[]
  events.completed = @[]
  events.errors = @[]
  events.finished.clear()

proc waitFinished*(
    events: HistoryQueryEvents, timeout: Duration
): Future[bool] {.async.} =
  ## True when a completed or error event comes within `timeout`.
  ## An event that came after the last `reset` also counts.
  return await events.finished.wait().withTimeout(timeout)

proc payloads*(events: HistoryQueryEvents): seq[string] =
  return events.messages.mapIt(string.fromBytes(it.message.payload))

proc teardown*(events: HistoryQueryEvents) {.async.} =
  await HistoryQueryMessageEvent.dropListener(events.ctx, events.messageListener)
  await HistoryQueryCompletedEvent.dropListener(events.ctx, events.completedListener)
  await HistoryQueryErrorEvent.dropListener(events.ctx, events.errorListener)
