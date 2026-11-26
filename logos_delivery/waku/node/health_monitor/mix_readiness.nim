{.push raises: [].}

## Whether mix can carry the messages of this node now. Mix health reports it and
## the send path asks it, so the two give one answer.

import logos_delivery/waku/waku_mix
import logos_delivery/waku/node/waku_node

const MixNotMountedReason* = "mix is not mounted"

const MixPoolTooSmallReason* =
  "mix knows fewer than " & $MinMixPoolSize & " usable mix nodes"
  ## The pool counts only members with an address that mix routes.

const MixNodesExcludedReason* =
  MixPoolTooSmallReason & " and knows mix nodes that it cannot use. " &
  MixAllowAllAddressesHint

const MixSelfHopReason* = "this node has no address that mix can use for replies"
  ## An IPv6-only or name-only announcement, or a NAT mapping not yet arrived.

const MixNoMembershipReason* = "this node has no usable Mix RLN membership"
  ## With Mix RLN, the sender proves the first hop. The membership can arrive
  ## later: the host's RLN module acquires it.

const MixNoExitReason* = "no mix node serves lightpush on the shard of the message"
  ## No pool member serves lightpush on the message's shard.

type MixUnusable* {.pure.} = enum
  ## Why mix cannot carry a message now.
  None
  NotMounted
  SelfHop
  NodesExcluded
  PoolTooSmall
  NoMembership
  NoExit

func reason*(unusable: MixUnusable): string =
  ## The text of mix health, of `errorDesc` and of the log lines.
  case unusable
  of MixUnusable.None: ""
  of MixUnusable.NotMounted: MixNotMountedReason
  of MixUnusable.SelfHop: MixSelfHopReason
  of MixUnusable.NodesExcluded: MixNodesExcludedReason
  of MixUnusable.PoolTooSmall: MixPoolTooSmallReason
  of MixUnusable.NoMembership: MixNoMembershipReason
  of MixUnusable.NoExit: MixNoExitReason

proc mixUnusable*(node: WakuNode): MixUnusable =
  ## Why mix cannot carry any message of this node now, or `None`. It does not
  ## look for an exit, because an exit must serve the shard of the message.
  if node.wakuMix.isNil():
    return MixUnusable.NotMounted
  # Checked before the pool: discovery cannot fix a hop that the encoder
  # rejects, and every reply path and cover packet fails on it.
  if not node.wakuMix.selfHopUsable():
    return MixUnusable.SelfHop
  if node.getMixNodePoolSize() < MinMixPoolSize:
    if node.wakuMix.countExcluded() > 0:
      return MixUnusable.NodesExcluded
    return MixUnusable.PoolTooSmall
  if not node.mixAdvertReady():
    return MixUnusable.NoMembership
  return MixUnusable.None

{.pop.}
