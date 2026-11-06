## Owned pubsub interface: what logos-delivery needs from a libp2p stack.
##
## Everything here is expressed with plain value types (bytes, strings, ints,
## floats, durations) so that the same contract can later be carried over an
## FFI boundary. No nim-libp2p type may appear in this module.
{.push raises: [].}

import results, chronos

type
  PeerIdStr* = string ## Base58 text form of a peer id.

  ValidationResult* {.pure.} = enum
    Accept
    Reject
    Ignore

  PubSubPeerInfo* = object
    peerId*: PeerIdStr
    score*: float64

  PxPeer* = object ## A peer learnt through pubsub peer exchange.
    peerId*: PeerIdStr
    addrs*: seq[string]

  PubSubValidator* = proc(topic: string, data: seq[byte]): Future[ValidationResult] {.
    gcsafe, raises: []
  .}

  PubSubHandler* =
    proc(topic: string, data: seq[byte]): Future[void] {.gcsafe, raises: [].}

  PubSubPeerExchangeHandler* =
    proc(fromPeer: PeerIdStr, topic: string, peers: seq[PxPeer]) {.gcsafe, raises: [].}

  PubSubEventKind* {.pure.} = enum
    MessageReceived ## a message arrived from a peer, before validation
    MessageValidated ## a received message passed validation
    MessageSent ## a message was handed to a peer
    TopologyChanged ## a peer changed its subscriptions or mesh membership

  PubSubEvent* = object
    kind*: PubSubEventKind
    peerId*: PeerIdStr
    topic*: string
    msgId*: string
    data*: seq[byte]
    subscriptionsChanged*: bool
    meshTopics*: seq[string] ## topics with a GRAFT/PRUNE (TopologyChanged only)

  PubSubEventHandler* = proc(event: PubSubEvent) {.gcsafe, raises: [].}

  PubSubParams* = object
    pruneBackoff*: Duration
    unsubscribeBackoff*: Duration
    floodPublish*: bool
    gossipFactor*: float64
    d*: int
    dLow*: int
    dHigh*: int
    dScore*: int
    dOut*: int
    dLazy*: int
    heartbeatInterval*: Duration
    historyLength*: int
    historyGossip*: int
    fanoutTTL*: Duration
    seenTTL*: Duration
    gossipThreshold*: float64
    publishThreshold*: float64
    graylistThreshold*: float64
    opportunisticGraftThreshold*: float64
    decayInterval*: Duration
    decayToZero*: float64
    retainScore*: Duration
    appSpecificWeight*: float64
    ipColocationFactorWeight*: float64
    ipColocationFactorThreshold*: float64
    behaviourPenaltyWeight*: float64
    behaviourPenaltyDecay*: float64
    disconnectBadPeers*: bool

  TopicScoreParams* = object
    topicWeight*: float64
    timeInMeshWeight*: float64
    timeInMeshQuantum*: Duration
    timeInMeshCap*: float64
    firstMessageDeliveriesWeight*: float64
    firstMessageDeliveriesDecay*: float64
    firstMessageDeliveriesCap*: float64
    meshMessageDeliveriesWeight*: float64
    meshMessageDeliveriesDecay*: float64
    meshMessageDeliveriesThreshold*: float64
    meshMessageDeliveriesCap*: float64
    meshMessageDeliveriesActivation*: Duration
    meshMessageDeliveriesWindow*: Duration
    meshFailurePenaltyWeight*: float64
    meshFailurePenaltyDecay*: float64
    invalidMessageDeliveriesWeight*: float64
    invalidMessageDeliveriesDecay*: float64

type IPubSub* = concept p
  # Contract a pubsub backend must satisfy. A backend is any type for which
  # these calls compile; there is no base class and no dynamic dispatch.
  p.start() is Future[void]
  p.stop() is Future[void]
  p.subscribe(string, PubSubHandler)
  p.unsubscribe(string)
  p.unsubscribeAll(string)
  p.publish(string, seq[byte]) is Future[int]
    # number of peers the message was relayed to
  p.addValidator(string, PubSubValidator)
  p.removeValidator(string)
  p.setTopicScoreParams(string, TopicScoreParams)
  p.topics() is seq[string]
  p.meshPeers(string) is Result[seq[PubSubPeerInfo], string]
    # empty topic: peers of every mesh
  p.connectedPeers(string) is Result[seq[PubSubPeerInfo], string]
    # empty topic: every connected peer
  p.params() is PubSubParams
  p.selfPeerId() is PeerIdStr
  p.setEventHandler(PubSubEventHandler)
  p.setTriggerSelf(bool)
  p.enablePeerExchange(PubSubPeerExchangeHandler)

func shortPeerId*(peerId: PeerIdStr): string =
  ## Compact form of a peer id for logs, e.g. `16Uiu2...SXsG3e`.
  const Edge = 6
  if peerId.len <= Edge * 2 + 3:
    return peerId
  return peerId[0 ..< Edge] & "..." & peerId[peerId.len - Edge .. peerId.high]
