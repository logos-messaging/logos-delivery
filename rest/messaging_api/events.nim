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
  # Nothing feeds the cache any more, so what it buffered is stale.
  self.cache.clear()

proc listenFailed(event, reason: string): string =
  return "could not listen for " & event & ": " & reason

proc start*(self: MessagingRestEvents, ctx: BrokerContext): Result[void, string] =
  ## Registers the listeners that are not yet registered, so it is idempotent
  ## and a retry after a partial failure completes the set.
  let cache = self.cache

  if self.sent.isNone():
    let listener = MessageSentEvent.listenIt(ctx):
      cache.recordSend($it.requestId, it.messageHash, SendEventKind.Sent)
    let registered = listener.valueOr:
      return err(listenFailed("MessageSentEvent", error))
    self.sent = Opt.some(registered)
  if self.queued.isNone():
    let listener = MessageQueuedEvent.listenIt(ctx):
      cache.recordSend($it.requestId, it.messageHash, SendEventKind.Queued)
    let registered = listener.valueOr:
      return err(listenFailed("MessageQueuedEvent", error))
    self.queued = Opt.some(registered)
  if self.propagated.isNone():
    let listener = MessagePropagatedEvent.listenIt(ctx):
      cache.recordSend($it.requestId, it.messageHash, SendEventKind.Propagated)
    let registered = listener.valueOr:
      return err(listenFailed("MessagePropagatedEvent", error))
    self.propagated = Opt.some(registered)
  if self.errored.isNone():
    let listener = MessageErrorEvent.listenIt(ctx):
      cache.recordSend($it.requestId, it.messageHash, SendEventKind.Error, it.error)
    let registered = listener.valueOr:
      return err(listenFailed("MessageErrorEvent", error))
    self.errored = Opt.some(registered)
  if self.received.isNone():
    let listener = MessageReceivedEvent.listenIt(ctx):
      cache.recordReceived(it.messageHash, toRelayWakuMessage(it.message), it.source)
    let registered = listener.valueOr:
      return err(listenFailed("MessageReceivedEvent", error))
    self.received = Opt.some(registered)
  return ok()
