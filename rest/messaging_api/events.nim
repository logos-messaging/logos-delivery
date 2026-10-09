## Feeds the messaging REST event cache from the MessagingClient events.
##
## Owned by the RestService: the listeners are registered by `start` and
## dropped by `stop`, so a stopped service leaves nothing behind on the broker
## context.

{.push raises: [].}

import results, chronos
import
  logos_delivery/api/events/messaging_client_events,
  logos_delivery/api/types,
  rest/messaging_api/event_cache,
  rest/messaging_api/types

type MessagingRestEvents* = ref object
  cache*: MessagingEventCache
  sent: Opt[MessageSentEventListener]
  queued: Opt[MessageQueuedEventListener]
  propagated: Opt[MessagePropagatedEventListener]
  errored: Opt[MessageErrorEventListener]
  received: Opt[MessageReceivedEventListener]

proc new*(T: type MessagingRestEvents, cache: MessagingEventCache): T =
  return T(cache: cache)

proc isListening*(self: MessagingRestEvents): bool =
  return self.sent.isSome()

proc stop*(self: MessagingRestEvents, ctx: BrokerContext) {.async: (raises: []).} =
  if self.sent.isSome():
    await MessageSentEvent.dropListener(ctx, self.sent.get())
    self.sent = Opt.none(MessageSentEventListener)
  if self.queued.isSome():
    await MessageQueuedEvent.dropListener(ctx, self.queued.get())
    self.queued = Opt.none(MessageQueuedEventListener)
  if self.propagated.isSome():
    await MessagePropagatedEvent.dropListener(ctx, self.propagated.get())
    self.propagated = Opt.none(MessagePropagatedEventListener)
  if self.errored.isSome():
    await MessageErrorEvent.dropListener(ctx, self.errored.get())
    self.errored = Opt.none(MessageErrorEventListener)
  if self.received.isSome():
    await MessageReceivedEvent.dropListener(ctx, self.received.get())
    self.received = Opt.none(MessageReceivedEventListener)

proc start*(self: MessagingRestEvents, ctx: BrokerContext): Result[void, string] =
  ## Registers the listeners that are not yet registered, so it is idempotent
  ## and a retry after a partial failure completes the set.
  let cache = self.cache

  if self.sent.isNone():
    self.sent = Opt.some(
      ?MessageSentEvent
        .listen(
          ctx,
          proc(evt: MessageSentEvent): Future[void] {.async: (raises: []).} =
            cache.recordSend($evt.requestId, evt.messageHash, SendEventKind.Sent),
        )
        .mapErr(
          proc(e: string): string =
            "could not listen for MessageSentEvent: " & e
        )
    )
  if self.queued.isNone():
    self.queued = Opt.some(
      ?MessageQueuedEvent
        .listen(
          ctx,
          proc(evt: MessageQueuedEvent): Future[void] {.async: (raises: []).} =
            cache.recordSend($evt.requestId, evt.messageHash, SendEventKind.Queued),
        )
        .mapErr(
          proc(e: string): string =
            "could not listen for MessageQueuedEvent: " & e
        )
    )
  if self.propagated.isNone():
    self.propagated = Opt.some(
      ?MessagePropagatedEvent
        .listen(
          ctx,
          proc(evt: MessagePropagatedEvent): Future[void] {.async: (raises: []).} =
            cache.recordSend($evt.requestId, evt.messageHash, SendEventKind.Propagated),
        )
        .mapErr(
          proc(e: string): string =
            "could not listen for MessagePropagatedEvent: " & e
        )
    )
  if self.errored.isNone():
    self.errored = Opt.some(
      ?MessageErrorEvent
        .listen(
          ctx,
          proc(evt: MessageErrorEvent): Future[void] {.async: (raises: []).} =
            cache.recordSend(
              $evt.requestId, evt.messageHash, SendEventKind.Error, evt.error
            ),
        )
        .mapErr(
          proc(e: string): string =
            "could not listen for MessageErrorEvent: " & e
        )
    )
  if self.received.isNone():
    self.received = Opt.some(
      ?MessageReceivedEvent
        .listen(
          ctx,
          proc(evt: MessageReceivedEvent): Future[void] {.async: (raises: []).} =
            cache.recordReceived(
              evt.messageHash, toRelayWakuMessage(evt.message), evt.source
            ),
        )
        .mapErr(
          proc(e: string): string =
            "could not listen for MessageReceivedEvent: " & e
        )
    )
  return ok()
