proc relay_get_peers_in_mesh*(
    self: LogosDelivery, pubsubTopic: string
): Future[Result[string, string]] {.ffi.} =
  let peers = (await self.waku.relayPeersInMesh(PubsubTopic(pubsubTopic))).valueOr:
    return err(error)
  return ok(peers.join(","))

proc relay_get_num_peers_in_mesh*(
    self: LogosDelivery, pubsubTopic: string
): Future[Result[string, string]] {.ffi.} =
  let n = (await self.waku.relayNumPeersInMesh(PubsubTopic(pubsubTopic))).valueOr:
    return err(error)
  return ok($n)

proc relay_get_connected_peers*(
    self: LogosDelivery, pubsubTopic: string
): Future[Result[string, string]] {.ffi.} =
  let peers = (await self.waku.relayConnectedPeers(PubsubTopic(pubsubTopic))).valueOr:
    return err(error)
  return ok(peers.join(","))

proc relay_get_num_connected_peers*(
    self: LogosDelivery, pubsubTopic: string
): Future[Result[string, string]] {.ffi.} =
  let n = (await self.waku.relayNumConnectedPeers(PubsubTopic(pubsubTopic))).valueOr:
    return err(error)
  return ok($n)

proc relay_add_protected_shard*(
    self: LogosDelivery, clusterId: uint16, shardId: uint16, publicKey: string
): Future[Result[string, string]] {.ffi.} =
  (await self.waku.relayAddProtectedShard(clusterId, shardId, publicKey)).isOkOr:
    return err(error)
  return ok("")

proc relay_subscribe*(
    self: LogosDelivery, pubsubTopic: string
): Future[Result[string, string]] {.ffi.} =
  # Just establishes the subscription; delivery flows through the global
  # MessageSeenEvent listener (see the ctor in liblogosdelivery.nim).
  (await self.waku.relaySubscribe(PubsubTopic(pubsubTopic))).isOkOr:
    return err(error)
  return ok("")

proc relay_unsubscribe*(
    self: LogosDelivery, pubsubTopic: string
): Future[Result[string, string]] {.ffi.} =
  (await self.waku.relayUnsubscribe(PubsubTopic(pubsubTopic))).isOkOr:
    return err(error)
  return ok("")

proc relay_publish*(
    self: LogosDelivery, pubsubTopic: string, message: WakuMessage, timeoutMs: uint32
): Future[Result[string, string]] {.ffi.} =
  ## Returns the published message hash (0x-hex).
  let hash = (
    await self.waku.relayPublish(PubsubTopic(pubsubTopic), message, timeoutMs)
  ).valueOr:
    return err(error)
  return ok(hash)

proc relay_default_pubsub_topic*(
    self: LogosDelivery
): Future[Result[string, string]] {.ffi.} =
  return ok(string(self.waku.defaultPubsubTopic()))

proc relay_content_topic*(
    self: LogosDelivery,
    appName: string,
    appVersion: uint32,
    contentTopicName: string,
    encoding: string,
): Future[Result[string, string]] {.ffi.} =
  let contentTopic = self.waku.buildContentTopic(
    appName, appVersion, contentTopicName, encoding
  ).valueOr:
    return err(error)
  return ok(string(contentTopic))

proc relay_pubsub_topic*(
    self: LogosDelivery, topicName: string
): Future[Result[string, string]] {.ffi.} =
  let pubsubTopic = self.waku.buildPubsubTopic(topicName).valueOr:
    return err(error)
  return ok(string(pubsubTopic))
