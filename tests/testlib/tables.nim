import std/[tables, sequtils, options]

import logos_delivery/waku/waku_core/topics, ../testlib/wakucore

proc `==`*(
    table: Table[pubsub_topic.RelayShard, seq[NsContentTopic]],
    other: array[0 .. 0, (string, seq[string])],
): bool =
  let otherTyped = other.map(
    proc(item: (string, seq[string])): (RelayShard, seq[NsContentTopic]) =
      let
        (pubsubTopic, contentTopics) = item
        shard = RelayShard.parse(pubsubTopic).value()
        nsContentTopics = contentTopics.map(
          proc(contentTopic: string): NsContentTopic =
            NsContentTopic.parse(contentTopic).value()
        )
      return (shard, nsContentTopics)
  )

  table == otherTyped.toTable()
