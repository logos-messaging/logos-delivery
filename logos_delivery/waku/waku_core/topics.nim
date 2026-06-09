import ./topics/content_topic, ./topics/pubsub_topic, ./topics/sharding

export content_topic, pubsub_topic, sharding

type
  SubscriptionKind* = enum
    ContentSub
    ContentUnsub
    PubsubSub
    PubsubUnsub

  SubscriptionEvent* = tuple[kind: SubscriptionKind, topic: string]
