import logos_delivery/waku/compat/option_valueor
import options, std/[strutils, sequtils]
import chronicles, chronos, results, ffi
import
  logos_delivery/waku/waku_filter_v2/client,
  logos_delivery/waku/waku_core/message/message,
  logos_delivery/waku/waku,
  logos_delivery/waku/waku_relay,
  logos_delivery/waku/waku_filter_v2/common,
  logos_delivery/waku/waku_core/subscription/push_handler,
  logos_delivery/waku/node/peer_manager/peer_manager,
  logos_delivery/waku/waku_node,
  logos_delivery/waku/waku_core/topics/pubsub_topic,
  logos_delivery/waku/waku_core/topics/content_topic,
  library/events/json_message_event,
  library/declare_lib

const FilterOpTimeout = 5.seconds

proc checkFilterClientMounted(waku: Waku): Result[string, string] =
  if waku.node.wakuFilterClient.isNil():
    let errorMsg = "wakuFilterClient is not mounted"
    error "fail filter process", error = errorMsg
    return err(errorMsg)
  return ok("")

proc waku_filter_subscribe(
    ctx: ptr FFIContext[LogosDelivery],
    callback: FFICallBack,
    userData: pointer,
    pubSubTopic: cstring,
    contentTopics: cstring,
) {.ffi.} =
  proc onReceivedMessage(ctx: ptr FFIContext): WakuRelayHandler =
    return proc(pubsubTopic: PubsubTopic, msg: WakuMessage) {.async.} =
      callEventCallback(ctx, "onReceivedMessage"):
        $JsonMessageEvent.new(pubsubTopic, msg)

  checkFilterClientMounted(ctx.myLib[].waku).isOkOr:
    return err($error)

  var filterPushEventCallback = FilterPushHandler(onReceivedMessage(ctx))
  ctx.myLib[].waku.node.wakuFilterClient.registerPushHandler(filterPushEventCallback)

  let peer = ctx.myLib[].waku.node.peerManager.selectPeer(WakuFilterSubscribeCodec).valueOr:
    let errorMsg = "could not find peer with WakuFilterSubscribeCodec when subscribing"
    error "fail filter subscribe", error = errorMsg
    return err(errorMsg)

  let subFut = ctx.myLib[].waku.node.filterSubscribe(
    some(PubsubTopic($pubsubTopic)),
    ($contentTopics).split(",").mapIt(ContentTopic(it)),
    peer,
  )
  if not await subFut.withTimeout(FilterOpTimeout):
    let errorMsg = "filter subscription timed out"
    error "fail filter unsubscribe", error = errorMsg

    return err(errorMsg)

  return ok("")

proc waku_filter_unsubscribe(
    ctx: ptr FFIContext[LogosDelivery],
    callback: FFICallBack,
    userData: pointer,
    pubSubTopic: cstring,
    contentTopics: cstring,
) {.ffi.} =
  checkFilterClientMounted(ctx.myLib[].waku).isOkOr:
    return err($error)

  let peer = ctx.myLib[].waku.node.peerManager.selectPeer(WakuFilterSubscribeCodec).valueOr:
    let errorMsg =
      "could not find peer with WakuFilterSubscribeCodec when unsubscribing"
    error "fail filter process", error = errorMsg
    return err(errorMsg)

  let subFut = ctx.myLib[].waku.node.filterUnsubscribe(
    some(PubsubTopic($pubsubTopic)),
    ($contentTopics).split(",").mapIt(ContentTopic(it)),
    peer,
  )
  if not await subFut.withTimeout(FilterOpTimeout):
    let errorMsg = "filter un-subscription timed out"
    error "fail filter unsubscribe", error = errorMsg
    return err(errorMsg)
  return ok("")

proc waku_filter_unsubscribe_all(
    ctx: ptr FFIContext[LogosDelivery], callback: FFICallBack, userData: pointer
) {.ffi.} =
  checkFilterClientMounted(ctx.myLib[].waku).isOkOr:
    return err($error)

  let peer = ctx.myLib[].waku.node.peerManager.selectPeer(WakuFilterSubscribeCodec).valueOr:
    let errorMsg =
      "could not find peer with WakuFilterSubscribeCodec when unsubscribing all"
    error "fail filter unsubscribe all", error = errorMsg
    return err(errorMsg)

  let unsubFut = ctx.myLib[].waku.node.filterUnsubscribeAll(peer)

  if not await unsubFut.withTimeout(FilterOpTimeout):
    let errorMsg = "filter un-subscription all timed out"
    error "fail filter unsubscribe all", error = errorMsg

    return err(errorMsg)
  return ok("")
