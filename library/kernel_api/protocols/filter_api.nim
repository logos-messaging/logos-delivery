import std/[strutils, sequtils]
import chronicles, chronos, results, ffi
import
  logos_delivery,
  logos_delivery/waku/waku_core/message/message,
  logos_delivery/waku/waku_core/subscription/push_handler,
  logos_delivery/waku/waku_core/topics/pubsub_topic,
  logos_delivery/waku/waku_core/topics/content_topic,
  library/events/event_bodies,
  library/declare_lib

proc waku_filter_subscribe(
    ld: LogosDelivery, pubSubTopic: cstring, contentTopics: cstring
): Future[Result[string, string]] {.ffi.} =
  proc onReceivedMessage(): FilterPushHandler =
    return proc(pubsubTopic: PubsubTopic, msg: WakuMessage) {.async.} =
      dispatchFFIEventCbor("message", toRelayMessageBody(pubsubTopic, msg))

  (
    await ld.waku.filterSubscribe(
      PubsubTopic($pubSubTopic),
      ($contentTopics).split(",").mapIt(ContentTopic(it)),
      FilterPushHandler(onReceivedMessage()),
    )
  ).isOkOr:
    error "fail filter subscribe", error = error
    return err(error)
  return ok("")

proc waku_filter_unsubscribe(
    ld: LogosDelivery, pubSubTopic: cstring, contentTopics: cstring
): Future[Result[string, string]] {.ffi.} =
  (
    await ld.waku.filterUnsubscribe(
      PubsubTopic($pubSubTopic), ($contentTopics).split(",").mapIt(ContentTopic(it))
    )
  ).isOkOr:
    error "fail filter unsubscribe", error = error
    return err(error)
  return ok("")

proc waku_filter_unsubscribe_all(
    ld: LogosDelivery
): Future[Result[string, string]] {.ffi.} =
  (await ld.waku.filterUnsubscribeAll()).isOkOr:
    error "fail filter unsubscribe all", error = error
    return err(error)
  return ok("")
