## Edge lightpush + filter operations on the slim EdgeNode. Mirrors the logic in
## library/kernel_api/protocols/{lightpush,filter}_api.nim but operates on
## EdgeNode (peer manager + the two light clients) instead of the full Waku.

{.push raises: [].}

import std/[options, sequtils]
import chronos, chronicles, results
import
  ./edge_node,
  libp2p/switch,
  logos_delivery/waku/waku_core/codecs,
  logos_delivery/waku/waku_core/message/message,
  logos_delivery/waku/waku_core/peers,
  logos_delivery/waku/waku_core/topics/pubsub_topic,
  logos_delivery/waku/waku_core/topics/content_topic,
  logos_delivery/waku/waku_core/subscription/push_handler,
  logos_delivery/waku/waku_lightpush/client,
  logos_delivery/waku/waku_filter_v2/client,
  logos_delivery/waku/waku_store/client,
  logos_delivery/waku/waku_store/common,
  logos_delivery/waku/node/peer_manager/peer_manager

proc connectToServiceNode*(
    node: EdgeNode, maddrs: seq[string]
): Future[Result[void, string]] {.async.} =
  ## Dial the service node by /wss multiaddr and remember it. We talk to this one
  ## known server directly (its multiaddr carries the PeerId), so lightpush/filter
  ## don't depend on identify having populated the peer store.
  let peer = parsePeerInfo(maddrs).valueOr:
    return err("bad service node multiaddr: " & error)
  await node.peerManager.connectToNodes(maddrs, source = "edge")
  node.serviceNode = some(peer)
  return ok()

proc connectToStoreNode*(
    node: EdgeNode, maddrs: seq[string]
): Future[Result[void, string]] {.async.} =
  ## Dial a dedicated store peer. Optional: without it history queries go to the
  ## service node, which only works if that node also serves store.
  let peer = parsePeerInfo(maddrs).valueOr:
    return err("bad store node multiaddr: " & error)
  await node.peerManager.connectToNodes(maddrs, source = "edge-store")
  node.storeNode = some(peer)
  return ok()

proc storeQuery*(
    node: EdgeNode, request: StoreQueryRequest
): Future[Result[StoreQueryResponse, string]] {.async.} =
  ## Query history from the store peer (or the service node when none is set).
  ## Deliberately NOT `queryToAny`: that picks a peer via the peer store, which
  ## depends on identify having populated protocols — unreliable here, for the
  ## same reason `serviceNode` is used directly for lightpush/filter.
  if node.wakuStoreClient.isNil():
    return err("store client not mounted")
  let peer =
    if node.storeNode.isSome(): node.storeNode.get()
    elif node.serviceNode.isSome(): node.serviceNode.get()
    else: return err("no store peer: not connected")
  let res = await node.wakuStoreClient.query(request, peer)
  if res.isErr():
    return err($res.error)
  return ok(res.get())

proc lightpushPublish*(
    node: EdgeNode, pubsubTopic: string, msg: WakuMessage
): Future[Result[string, string]] {.async.} =
  ## Publish `msg` to a service node via the v3 lightpush client.
  if node.wakuLightpushClient.isNil():
    return err("lightpush client not mounted")
  if node.serviceNode.isNone():
    return err("not connected to a service node")
  # Dial the protocol on the peer id, NOT on a RemotePeerInfo.
  #
  # Passing RemotePeerInfo routes through peerManager.dialPeer, which calls
  # switch.dial(peerId, ADDRS, proto) — an address-based dial that tries to establish a
  # fresh connection rather than reuse the one we already hold. In a browser that fails
  # ("dial_failure: <peer> is not accessible") even though the WebSocket to the service
  # node is up and healthy, so every publish died while connect, filter and store-connect
  # all worked. Dialing by peer id lets the switch hand back a stream over the existing
  # muxed connection.
  let peer = node.serviceNode.get()
  let conn =
    try:
      await node.switch.dial(peer.peerId, @[WakuLightPushCodec])
    except CatchableError as e:
      return err("lightpush stream dial failed: " & e.msg)
  let res =
    await node.wakuLightpushClient.publish(some(PubsubTopic(pubsubTopic)), msg, conn)
  if res.isErr():
    return err($res.error)
  return ok("published to " & $res.get() & " relay peer(s)")

proc filterSubscribe*(
    node: EdgeNode,
    pubsubTopic: string,
    contentTopics: seq[string],
    handler: FilterPushHandler,
): Future[Result[void, string]] {.async.} =
  ## Subscribe to `contentTopics` on a service node; `handler` fires per push.
  if node.wakuFilterClient.isNil():
    return err("filter client not mounted")
  if node.serviceNode.isNone():
    return err("not connected to a service node")
  node.wakuFilterClient.registerPushHandler(handler)
  let res = await node.wakuFilterClient.subscribe(
    node.serviceNode.get(), PubsubTopic(pubsubTopic),
    contentTopics.mapIt(ContentTopic(it)),
  )
  if res.isErr():
    return err($res.error)
  return ok()
