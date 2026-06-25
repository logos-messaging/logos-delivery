## Per-shard (pubsub topic) health changes, fed by EventShardTopicHealthChange.

proc onTopicHealthChange*(
  pubsubTopic: string, health: string
) {.ffiEvent: "on_topic_health_change".}

proc listenTopicHealthEvents(self: LogosDelivery) =
  discard EventShardTopicHealthChange.listen(
    self.waku.brokerCtx,
    proc(e: EventShardTopicHealthChange) {.async: (raises: []).} =
      onTopicHealthChange(string(e.topic), $e.health),
  )
