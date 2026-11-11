import chronos, results, stew/byteutils, libp2p/[peerid, multiaddress]
import
  logos_delivery,
  logos_delivery/api/types,
  logos_delivery/messaging/[messaging_client, api/send],
  logos_delivery/waku/[waku_core, node/peer_manager, waku_lightpush/common]
import ./[futures, wakucore]

proc sendWhenConnected*(
    client: MessagingClient, envelope: MessageEnvelope, timeout = FUTURE_TIMEOUT_LONG
): Future[SendResult] {.async.} =
  ## Sends `envelope` again while the node has no peer to send through.
  ## An app does the same after `NotConnected`, and after `QueueFull`.
  ## A node knows the peers of a shard only after they exchange their subscriptions.
  ## So a test that connects a node and sends at once needs this proc.
  let deadline = Moment.now() + timeout
  while true:
    let res = await client.send(envelope)
    if res.isOk() or
        res.error.kind notin {SendErrorKind.NotConnected, SendErrorKind.QueueFull} or
        Moment.now() > deadline:
      return res
    await sleepAsync(chronos.milliseconds(5))

proc addUnreachableLightpushPeer*(node: LogosDelivery) =
  ## Gives `node` a lightpush service peer at an address where nothing listens.
  ## So `send` accepts a message, and no attempt of the message propagates.
  node.waku.node.peerManager.addServicePeer(
    RemotePeerInfo.init(
      PeerId.init(generateSecp256k1Key()).expect("peer id"),
      @[MultiAddress.init("/ip4/127.0.0.1/tcp/1").expect("address")],
      protocols = @[WakuLightPushCodec],
      shards = @[0'u16],
    ),
    WakuLightPushCodec,
  )

proc fakeHash*(id: string): WakuMessageHash =
  ## The message hash that a fake `MessagingSend` provider returns.
  ## Each id gives its own hash.
  return computeMessageHash(DefaultPubsubTopic, WakuMessage(payload: id.toBytes()))
