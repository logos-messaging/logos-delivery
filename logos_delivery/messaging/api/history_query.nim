## Messaging layer API — history query operation.
import results, chronos, chronicles

import logos_delivery/api/types
import logos_delivery/messaging/messaging_client
import logos_delivery/waku/waku
import logos_delivery/waku/api/subscriptions
import logos_delivery/messaging/delivery_service/history_query_service

proc startHistoryQuery(
    self: MessagingClient, requestId: RequestId, query: HistoryQuery
): Result[void, string] =
  if not self.waku.isAutoshardingConfigured():
    return err("autosharding is not configured, so the content topic has no shard")
  let shards = ?self.waku.contentTopicShards(query.contentTopic)
  return self.historyQueryService.startQuery(requestId, query, shards)

proc queryHistory*(
    self: MessagingClient, query: HistoryQuery
): Future[Result[RequestId, string]] {.async.} =
  ## Starts a history query and returns its request id, before any event of the query.
  ## The messaging layer selects the history sources, Store nodes at this time.
  ## The app does not need to subscribe to the content topic.
  ## Each message comes in a `HistoryQueryMessageEvent`, not sorted by timestamp.
  ## Then a `HistoryQueryCompletedEvent` or a `HistoryQueryErrorEvent` ends the query.
  ## A message can also come in a `MessageReceivedEvent`, with the same hash.
  ## A stop of the client cancels the query, and then no event ends it.
  ## The call fails while `MaxActiveHistoryQueries` queries are active.
  ?self.checkApiAvailability()
  let requestId = RequestId.new(self.waku.rng)
  self.startHistoryQuery(requestId, query).isOkOr:
    error "Failed to start a history query",
      requestId, contentTopic = query.contentTopic, error
    return err("MessagingClient.queryHistory: " & error)
  return ok(requestId)
