## Waku message envelope.
##
## Bundles a decoded `WakuMessage` with its `pubsubTopic` and the deterministic
## `WakuMessageHash`, computed **once** at construction. The envelope is the unit
## that flows through the internal relay dispatch (relay topic handler ->
## subscription_manager -> archive / filter / store-sync / app handlers) so that
## the same message is neither re-decoded nor re-hashed by each consumer.
##
## Like `WakuMessage`, a `WakuEnvelope` is a `ref object` and **immutable by
## convention**: construct it once after validation and never mutate it. Under
## `--mm:refc` passing it around is a pointer + refcount, not a deep copy.

{.push raises: [].}

import ../topics, ./message, ./digest

type WakuEnvelope* = ref object
  msg*: WakuMessage
  pubsubTopic*: PubsubTopic
  hash*: WakuMessageHash

proc init*(T: type WakuEnvelope, pubsubTopic: PubsubTopic, msg: WakuMessage): T =
  ## Builds an envelope, computing the message hash once (the single inbound-path
  ## hash). `msg` is referenced, not copied.
  WakuEnvelope(
    msg: msg, pubsubTopic: pubsubTopic, hash: computeMessageHash(pubsubTopic, msg)
  )

proc shortLog*(envelope: WakuEnvelope): string =
  ## Compact chronicles representation: short hash + topic.
  if envelope.isNil():
    return "nil"
  "hash=" & envelope.hash.to0xHex() & " topic=" & envelope.pubsubTopic

proc `$`*(envelope: WakuEnvelope): string =
  shortLog(envelope)

{.pop.}
