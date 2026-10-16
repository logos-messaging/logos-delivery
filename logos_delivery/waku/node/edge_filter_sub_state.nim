{.push raises: [].}

import std/sets
import chronos, libp2p/peerid
import ../waku_core, ./health_monitor/topic_health

type EdgeFilterSubState* = object
  peers*: seq[RemotePeerInfo]
  pending*: seq[Future[void]]
  pendingPeers*: HashSet[PeerId]
  currentHealth*: TopicHealth
  staticFilterPeerTries*: int
    ## The number of failed tries to filter-subscribe through the configured
    ## filter peer, for the shard that is the key of this state in
    ## `edgeFilterSubStates`. Each tick of `edgeFilterConnectionLoop` that finds
    ## that shard with fewer than `HealthyThreshold` peers resets it.

{.pop.}
