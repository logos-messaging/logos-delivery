## The messaging REST service: mounts the `/messaging` routes and feeds their
## event cache from the MessagingClient events.
##
## It sits above the messaging layer (like the FFI library): the client knows
## nothing about it. The cache outlives restarts (the mounted routes capture
## it); the listeners are registered by `start` and dropped by `stop`, so a
## stopped client leaves nothing behind on the broker context.

{.push raises: [].}

import results, chronos, chronicles
import
  logos_delivery/api/events/messaging_client_events,
  logos_delivery/api/types,
  logos_delivery/waku/waku,
  logos_delivery/waku/rest_api/endpoint/builder as rest_server_builder,
  logos_delivery/messaging/messaging_client,
  ./event_cache,
  ./handlers,
  ./types

logScope:
  topics = "messaging rest api"

type MessagingRestService* = ref object
  cache*: MessagingEventCache
  sent: Opt[MessageSentEventListener]
  queued: Opt[MessageQueuedEventListener]
  propagated: Opt[MessagePropagatedEventListener]
  errored: Opt[MessageErrorEventListener]
  received: Opt[MessageReceivedEventListener]

proc new*(T: type MessagingRestService, cache: MessagingEventCache): T =
  return T(cache: cache)

proc isListening*(self: MessagingRestService): bool =
  return self.sent.isSome()

proc stop*(self: MessagingRestService, ctx: BrokerContext) {.async: (raises: []).} =
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

proc start*(self: MessagingRestService, ctx: BrokerContext): Result[void, string] =
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

proc mount*(T: type MessagingRestService, client: MessagingClient): T =
  ## Mounts the messaging REST endpoints onto the kernel-owned REST router, if
  ## the REST server is enabled, and returns the service that feeds their event
  ## cache (nil when REST is disabled). The routes are mounted once, since
  ## presto rejects a route added twice; the caller starts and stops the
  ## returned listeners with the client.
  if client.waku.restServer.isNil():
    return nil
  # The BTree route table is ref-backed, so mutating the copied router persists
  # (same pattern as the waku REST builder).
  let capacity =
    if client.waku.conf.restServerConf.isSome():
      int(client.waku.conf.restServerConf.get().messagingCacheCapacity)
    else:
      DefaultMaxReceived
  let events = MessagingRestService.new(MessagingEventCache.new(maxReceived = capacity))
  var router = client.waku.restServer.router
  installMessagingApiHandlers(router, client, events.cache)
  rest_server_builder.markRestApiInstalled(rest_server_builder.RestRootMessaging)
  info "Mounted messaging REST API endpoints"
  return events
