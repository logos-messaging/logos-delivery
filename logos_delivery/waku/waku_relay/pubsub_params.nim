## Waku Relay policy: GossipSub and per-topic scoring parameters, expressed with
## the backend-neutral types of the pubsub interface.
{.push raises: [].}

import chronos
import ../libp2p_iface/pubsub

## Slack the gossipsub backoff logic adds on top of the prune backoff.
const PruneBackoffSlack* = chronos.seconds(2)

# see: https://github.com/libp2p/specs/blob/master/pubsub/gossipsub/gossipsub-v1.1.md#overview-of-new-parameters
const WakuTopicScoreParams* = TopicScoreParams(
  topicWeight: 1,

  # p1: favours peers already in the mesh
  timeInMeshWeight: 0.01,
  timeInMeshQuantum: 1.seconds,
  timeInMeshCap: 10.0,

  # p2: rewards fast peers
  firstMessageDeliveriesWeight: 1.0,
  firstMessageDeliveriesDecay: 0.5,
  firstMessageDeliveriesCap: 10.0,

  # p3: penalizes lazy peers. safe low value
  meshMessageDeliveriesWeight: 0.0,
  meshMessageDeliveriesDecay: 0.0,
  meshMessageDeliveriesCap: 0,
  meshMessageDeliveriesThreshold: 0,
  meshMessageDeliveriesWindow: 0.milliseconds,
  meshMessageDeliveriesActivation: 0.seconds,

  # p3b: tracks history of prunes
  meshFailurePenaltyWeight: 0.0,
  meshFailurePenaltyDecay: 0.0,

  # p4: penalizes invalid messages. highly penalize
  # peers sending wrong messages
  invalidMessageDeliveriesWeight: -100.0,
  invalidMessageDeliveriesDecay: 0.5,
)

# see: https://rfc.vac.dev/spec/29/#gossipsub-v10-parameters
const WakuPubSubParams* = PubSubParams(
  pruneBackoff: chronos.minutes(1),
  unsubscribeBackoff: chronos.seconds(5),
  floodPublish: true,
  gossipFactor: 0.25,
  d: 6,
  dLow: 4,
  dHigh: 8,
  dScore: 6,
  dOut: 3,
  dLazy: 6,
  heartbeatInterval: chronos.seconds(1),
  historyLength: 6,
  historyGossip: 3,
  fanoutTTL: chronos.minutes(1),
  seenTTL: chronos.minutes(2),

  # no gossip is sent to peers below this score
  gossipThreshold: -100,

  # no self-published msgs are sent to peers below this score
  publishThreshold: -1000,

  # used to trigger disconnections + ignore peer if below this score
  graylistThreshold: -10000,

  # grafts better peers if the mesh median score drops below this. unset.
  opportunisticGraftThreshold: 0,

  # how often peer scoring is updated
  decayInterval: chronos.seconds(12),

  # below this we consider the parameter to be zero
  decayToZero: 0.01,

  # remember peer score during x after it disconnects
  retainScore: chronos.minutes(10),

  # p5: application specific, unset
  appSpecificWeight: 0.0,

  # p6: penalizes peers sharing more than threshold ips
  ipColocationFactorWeight: -50.0,
  ipColocationFactorThreshold: 5.0,

  # p7: penalizes bad behaviour (weight and decay)
  behaviourPenaltyWeight: -10.0,
  behaviourPenaltyDecay: 0.986,

  # triggers disconnections of bad peers aka score <graylistThreshold
  disconnectBadPeers: true,
)
