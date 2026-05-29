{.push raises: [].}

import
  std/[options, tables, sets],
  chronos,
  results,
  eth/keys,
  bearssl/rand,
  eth/p2p/discoveryv5/enr,
  libp2p/crypto/crypto,
  libp2p/[multiaddress, multicodec],
  libp2p/protocols/ping,
  libp2p/protocols/mix/mix_protocol,
  brokers/broker_context

import
  waku/[
    waku_core,
    waku_relay,
    waku_archive,
    waku_store/protocol as store,
    waku_store/client as store_client,
    waku_store/resume,
    waku_store_sync,
    waku_filter_v2,
    waku_filter_v2/client as filter_client,
    waku_metadata,
    waku_rendezvous/protocol,
    waku_rendezvous/client as rendezvous_client,
    waku_lightpush_legacy/client as legacy_lightpush_client,
    waku_lightpush_legacy as legacy_lightpush_protocol,
    waku_lightpush/client as lightpush_client,
    waku_lightpush as lightpush_protocol,
    waku_peer_exchange,
    waku_rln_relay,
    waku_mix,
    common/rate_limit/setting,
    discovery/waku_kademlia,
    net/bound_ports,
    events/peer_events,
  ],
  ./peer_manager,
  ./health_monitor/topic_health

# key and crypto modules different
type
  # TODO: Move to application instance (e.g., `WakuNode2`)
  WakuInfo* = object # NOTE One for simplicity, can extend later as needed
    listenAddresses*: seq[string]
    enrUri*: string #multiaddrStrings*: seq[string]
    mixPubKey*: Option[string]

  # NOTE based on Eth2Node in NBC eth2_network.nim
  WakuNode* = ref object
    peerManager*: PeerManager
    switch*: Switch
    wakuRelay*: WakuRelay
    wakuArchive*: waku_archive.WakuArchive
    wakuStore*: store.WakuStore
    wakuStoreClient*: store_client.WakuStoreClient
    wakuStoreResume*: StoreResume
    wakuStoreReconciliation*: SyncReconciliation
    wakuStoreTransfer*: SyncTransfer
    wakuFilter*: waku_filter_v2.WakuFilter
    wakuFilterClient*: filter_client.WakuFilterClient
    wakuRlnRelay*: WakuRLNRelay
    wakuLegacyLightPush*: WakuLegacyLightPush
    wakuLegacyLightpushClient*: WakuLegacyLightPushClient
    wakuLightPush*: WakuLightPush
    wakuLightpushClient*: WakuLightPushClient
    wakuPeerExchange*: WakuPeerExchange
    wakuPeerExchangeClient*: WakuPeerExchangeClient
    wakuMetadata*: WakuMetadata
    wakuAutoSharding*: Option[Sharding]
    enr*: enr.Record
    libp2pPing*: Ping
    rng*: ref rand.HmacDrbgContext
    brokerCtx*: BrokerContext
    wakuRendezvous*: WakuRendezVous
    wakuRendezvousClient*: rendezvous_client.WakuRendezVousClient
    announcedAddresses*: seq[MultiAddress]
    extMultiAddrsOnly*: bool # When true, skip automatic IP address replacement
    started*: bool # Indicates that node has started listening
    topicSubscriptionQueue*: AsyncEventQueue[SubscriptionEvent]
    rateLimitSettings*: ProtocolRateLimitSettings
    legacyAppHandlers*: Table[PubsubTopic, WakuRelayHandler]
      ## Kernel API Relay appHandlers (if any)
    subscriptionManager*: SubscriptionManager
    wakuMix*: WakuMix
    kademliaDiscoveryLoop*: Future[void]
    wakuKademlia*: WakuKademlia
    ports*: BoundPorts

  ShardSubscription* = object
    contentTopics*: HashSet[ContentTopic]
    directShardSub*: bool ## shard subscribed directly (PubsubSub), independent of content-topic interest

  EdgeFilterSubState* = object
    peers*: seq[RemotePeerInfo]
    pending*: seq[Future[void]]
    pendingPeers*: HashSet[PeerId]
    currentHealth*: TopicHealth

  SubscriptionManager* = ref object of RootObj
    node*: WakuNode
    shards*: Table[PubsubTopic, ShardSubscription]
    edgeFilterSubStates*: Table[PubsubTopic, EdgeFilterSubState]
    edgeFilterWakeup*: AsyncEvent
    edgeFilterSubLoopFut*: Future[void]
    edgeFilterConnectionLoopFut*: Future[void]
    peerEventListener*: WakuPeerEventListener

{.pop.}
