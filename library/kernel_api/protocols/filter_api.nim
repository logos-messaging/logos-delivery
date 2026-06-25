import std/sequtils
import logos_delivery/waku/waku_core/subscription/push_handler

proc filter_subscribe*(
    self: LogosDelivery, pubsubTopic: string, contentTopics: seq[string]
): Future[Result[string, string]] {.ffi.} =
  # `filterSubscribe` re-registers the filter push handler, so it must keep
  # feeding MessageSeenEvent — the single source the ctor's listener delivers
  # to the foreign side (see liblogosdelivery.nim).
  let brokerCtx = self.waku.brokerCtx
  let pushHandler = proc(pubsubTopic: PubsubTopic, msg: WakuMessage) {.async.} =
    MessageSeenEvent.emit(brokerCtx, pubsubTopic, msg)
  (
    await self.waku.filterSubscribe(
      PubsubTopic(pubsubTopic),
      contentTopics.mapIt(ContentTopic(it)),
      FilterPushHandler(pushHandler),
    )
  ).isOkOr:
    return err(error)
  return ok("")

proc filter_unsubscribe*(
    self: LogosDelivery, pubsubTopic: string, contentTopics: seq[string]
): Future[Result[string, string]] {.ffi.} =
  (
    await self.waku.filterUnsubscribe(
      PubsubTopic(pubsubTopic), contentTopics.mapIt(ContentTopic(it))
    )
  ).isOkOr:
    return err(error)
  return ok("")

proc filter_unsubscribe_all*(
    self: LogosDelivery
): Future[Result[string, string]] {.ffi.} =
  (await self.waku.filterUnsubscribeAll()).isOkOr:
    return err(error)
  return ok("")
