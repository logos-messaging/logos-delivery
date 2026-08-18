import std/[strutils, sequtils]
import chronicles, chronos, results, ffi
import
  logos_delivery,
  logos_delivery/waku/waku_core/message/message,
  logos_delivery/waku/waku_core/subscription/push_handler,
  logos_delivery/waku/waku_core/topics/pubsub_topic,
  logos_delivery/waku/waku_core/topics/content_topic,
  library/events/json_message_event,
  library/declare_lib

proc waku_filter_subscribe(
    self: LogosDelivery, pubSubTopic: string, contentTopics: string
): Future[Result[string, string]] {.ffi.} =
  proc onReceivedMessage(): FilterPushHandler =
    return proc(pubsubTopic: PubsubTopic, msg: WakuMessage) {.async.} =
      emitEvent("onReceivedMessage"):
        $JsonMessageEvent.new(pubsubTopic, msg)

  (
    await self.waku.filterSubscribe(
      PubsubTopic(pubSubTopic),
      contentTopics.split(",").mapIt(ContentTopic(it)),
      FilterPushHandler(onReceivedMessage()),
    )
  ).isOkOr:
    error "Fail filter subscribe", error = error
    return err(error)
  return ok("")

proc waku_filter_unsubscribe(
    self: LogosDelivery, pubSubTopic: string, contentTopics: string
): Future[Result[string, string]] {.ffi.} =
  (
    await self.waku.filterUnsubscribe(
      PubsubTopic(pubSubTopic), contentTopics.split(",").mapIt(ContentTopic(it))
    )
  ).isOkOr:
    error "Fail filter unsubscribe", error = error
    return err(error)
  return ok("")

proc waku_filter_unsubscribe_all(
    self: LogosDelivery
): Future[Result[string, string]] {.ffi.} =
  (await self.waku.filterUnsubscribeAll()).isOkOr:
    error "Fail filter unsubscribe all", error = error
    return err(error)
  return ok("")
