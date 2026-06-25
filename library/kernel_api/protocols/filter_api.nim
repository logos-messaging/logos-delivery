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
    ctx: ptr FFIContext[LogosDelivery],
    callback: FFICallBack,
    userData: pointer,
    pubSubTopic: cstring,
    contentTopics: cstring,
) {.ffi.} =
  proc onReceivedMessage(ctx: ptr FFIContext[LogosDelivery]): FilterPushHandler =
    return proc(pubsubTopic: PubsubTopic, msg: WakuMessage) {.async.} =
      callEventCallback(ctx, "onReceivedMessage"):
        $JsonMessageEvent.new(pubsubTopic, msg)

  (
    await ctx.myLib[].waku.filterSubscribe(
      PubsubTopic($pubSubTopic),
      ($contentTopics).split(",").mapIt(ContentTopic(it)),
      FilterPushHandler(onReceivedMessage(ctx)),
    )
  ).isOkOr:
    error "fail filter subscribe", error = error
    return err(error)
  return ok("")

proc waku_filter_unsubscribe(
    ctx: ptr FFIContext[LogosDelivery],
    callback: FFICallBack,
    userData: pointer,
    pubSubTopic: cstring,
    contentTopics: cstring,
) {.ffi.} =
  (
    await ctx.myLib[].waku.filterUnsubscribe(
      PubsubTopic($pubSubTopic), ($contentTopics).split(",").mapIt(ContentTopic(it))
    )
  ).isOkOr:
    error "fail filter unsubscribe", error = error
    return err(error)
  return ok("")

proc waku_filter_unsubscribe_all(
    ctx: ptr FFIContext[LogosDelivery], callback: FFICallBack, userData: pointer
) {.ffi.} =
  (await ctx.myLib[].waku.filterUnsubscribeAll()).isOkOr:
    error "fail filter unsubscribe all", error = error
    return err(error)
  return ok("")
