## Wire contract between logos-delivery and a Logos module that provides the
## libp2p stack (host and pubsub).
##
## Everything crossing the boundary is a plain value: bytes, strings, integers,
## floats, booleans and objects/sequences of those, CBOR-encoded. Peer ids and
## multiaddresses travel as strings, streams as opaque `uint64` handles. There
## are no Nim refs, closures or futures in a payload, so each request and event
## below maps one to one onto a nim-ffi `{.ffi.}` request or `{.ffiEvent.}`.
##
## Direction:
## - a *request* goes from logos-delivery to the module and is answered with a
##   reply (CBOR result or an error string);
## - an *event* goes from the module to logos-delivery, unanswered, except the
##   validation event, which the verdict request answers.
##
## Validation is on the relay hot path: the module emits `EvPubSubValidate`, the
## relay validates and answers with `ReqPubSubVerdict`. A module that gets no
## verdict within `ValidationDeadlineMs` must treat the message as `ignore`.
{.push raises: [].}

import ffi/cbor_serial

export cbor_serial

const
  Libp2pModuleAbiVersion* = 1'u32
  ValidationDeadlineMs* = 2000

  # --- pubsub requests
  ReqPubSubConfigure* = "pubsub.configure"
  ReqPubSubStart* = "pubsub.start"
  ReqPubSubStop* = "pubsub.stop"
  ReqPubSubSubscribe* = "pubsub.subscribe"
  ReqPubSubUnsubscribe* = "pubsub.unsubscribe"
  ReqPubSubUnsubscribeAll* = "pubsub.unsubscribe_all"
  ReqPubSubPublish* = "pubsub.publish"
  ReqPubSubAddValidator* = "pubsub.add_validator"
  ReqPubSubRemoveValidator* = "pubsub.remove_validator"
  ReqPubSubVerdict* = "pubsub.validation_verdict"
  ReqPubSubTopicScore* = "pubsub.set_topic_score_params"
  ReqPubSubTopics* = "pubsub.topics"
  ReqPubSubMeshPeers* = "pubsub.mesh_peers"
  ReqPubSubConnectedPeers* = "pubsub.connected_peers"
  ReqPubSubSelfPeerId* = "pubsub.self_peer_id"
  ReqPubSubTriggerSelf* = "pubsub.set_trigger_self"
  ReqPubSubEnablePx* = "pubsub.enable_peer_exchange"

  # --- pubsub events
  EvPubSubMessage* = "pubsub.message" ## a validated message for a subscribed topic
  EvPubSubValidate* = "pubsub.validate"
  EvPubSubObserved* = "pubsub.observed"
    ## message received/validated/sent, topology change
  EvPubSubPeerExchange* = "pubsub.peer_exchange"

  # --- host requests
  ReqHostIdentity* = "host.identity"
  ReqHostStart* = "host.start"
  ReqHostStop* = "host.stop"
  ReqHostDisconnect* = "host.disconnect"
  ReqHostConnections* = "host.connections"
  ReqHostIsConnected* = "host.is_connected"
  ReqHostDial* = "host.dial"
  ReqHostMount* = "host.mount"

  # --- host events
  EvHostStream* = "host.stream" ## an inbound stream opened on a mounted codec
  EvHostPeer* = "host.peer"

  # --- stream requests
  ReqStreamWriteLp* = "stream.write_lp"
  ReqStreamReadLp* = "stream.read_lp"
  ReqStreamClose* = "stream.close"
  ReqStreamCloseWithEof* = "stream.close_with_eof"
  ReqStreamAtEof* = "stream.at_eof"

  # Prefixes of the error string a stream request answers with, so that the
  # stream can raise the matching error on this side.
  ErrStreamMaxSize* = "max_size: "
  ErrStreamRemoteClosed* = "remote_closed: "
  ErrStream* = "stream: "

type
  Empty* = object

  # --- pubsub payloads
  PubSubParamsDto* = object
    pruneBackoffMs*: int64
    unsubscribeBackoffMs*: int64
    floodPublish*: bool
    gossipFactor*: float64
    d*, dLow*, dHigh*, dScore*, dOut*, dLazy*: int64
    heartbeatIntervalMs*: int64
    historyLength*, historyGossip*: int64
    fanoutTtlMs*, seenTtlMs*: int64
    gossipThreshold*, publishThreshold*, graylistThreshold*: float64
    opportunisticGraftThreshold*: float64
    decayIntervalMs*: int64
    decayToZero*: float64
    retainScoreMs*: int64
    appSpecificWeight*: float64
    ipColocationFactorWeight*, ipColocationFactorThreshold*: float64
    behaviourPenaltyWeight*, behaviourPenaltyDecay*: float64
    disconnectBadPeers*: bool

  TopicScoreParamsDto* = object
    topicWeight*: float64
    timeInMeshWeight*: float64
    timeInMeshQuantumMs*: int64
    timeInMeshCap*: float64
    firstMessageDeliveriesWeight*, firstMessageDeliveriesDecay*: float64
    firstMessageDeliveriesCap*: float64
    meshMessageDeliveriesWeight*, meshMessageDeliveriesDecay*: float64
    meshMessageDeliveriesThreshold*, meshMessageDeliveriesCap*: float64
    meshMessageDeliveriesActivationMs*, meshMessageDeliveriesWindowMs*: int64
    meshFailurePenaltyWeight*, meshFailurePenaltyDecay*: float64
    invalidMessageDeliveriesWeight*, invalidMessageDeliveriesDecay*: float64

  PubSubConfigureReq* = object
    codec*: string
    maxMessageSize*: int64
    params*: PubSubParamsDto

  TopicReq* = object
    topic*: string

  PublishReq* = object
    topic*: string
    data*: seq[byte]

  PublishRes* = object
    relayed*: int64

  VerdictReq* = object
    requestId*: uint64
    verdict*: uint8 ## 0 accept, 1 reject, 2 ignore

  TopicScoreReq* = object
    topic*: string
    params*: TopicScoreParamsDto

  PeerDto* = object
    peerId*: string
    score*: float64

  PeersReq* = object
    topic*: string ## empty: every mesh / every connected peer

  PeersRes* = object
    peers*: seq[PeerDto]

  TopicsRes* = object
    topics*: seq[string]

  PeerIdRes* = object
    peerId*: string

  TriggerSelfReq* = object
    value*: bool

  PubSubMessageEv* = object
    topic*: string
    data*: seq[byte]

  PubSubValidateEv* = object
    requestId*: uint64
    topic*: string
    data*: seq[byte]

  PubSubObservedEv* = object
    kind*: uint8 ## 0 received, 1 validated, 2 sent, 3 topology changed
    peerId*: string
    topic*: string
    msgId*: string
    data*: seq[byte]
    subscriptionsChanged*: bool
    meshTopics*: seq[string]

  PxPeerDto* = object
    peerId*: string
    addrs*: seq[string]

  PubSubPeerExchangeEv* = object
    fromPeer*: string
    topic*: string
    peers*: seq[PxPeerDto]

  # --- host payloads
  HostIdentityRes* = object
    peerId*: string
    listenAddrs*: seq[string]
    announcedAddrs*: seq[string]

  PeerReq* = object
    peerId*: string

  IsConnectedRes* = object
    connected*: bool

  StreamDto* = object
    protocol*: string
    inbound*: bool

  ConnectionDto* = object
    peerId*: string
    inbound*: bool
    observedAddr*: string ## empty when unknown
    streams*: seq[StreamDto]

  ConnectionsRes* = object
    connections*: seq[ConnectionDto]

  DialReq* = object
    peerId*: string
    addrs*: seq[string]
    codec*: string

  DialRes* = object
    handle*: uint64

  MountReq* = object
    codec*: string

  HostStreamEv* = object
    handle*: uint64
    peerId*: string
    codec*: string

  HostPeerEv* = object
    peerId*: string
    kind*: uint8 ## 0 joined, 1 left, 2 identified
    initiator*: bool

  # --- stream payloads
  StreamReq* = object
    handle*: uint64

  StreamWriteReq* = object
    handle*: uint64
    data*: seq[byte]

  StreamReadReq* = object
    handle*: uint64
    maxSize*: int64

  StreamReadRes* = object
    data*: seq[byte]

  StreamAtEofRes* = object
    atEof*: bool
