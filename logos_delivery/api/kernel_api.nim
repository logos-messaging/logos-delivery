import chronos, results

import logos_delivery/api/types as api_types
import logos_delivery/waku/waku_core/topics/pubsub_topic
import logos_delivery/waku/waku_core/message
import logos_delivery/waku/waku_core/subscription/push_handler
import logos_delivery/waku/waku_store/common as store_types

export api_types, pubsub_topic, store_types

# Structural API contract for the Kernel surface, implemented by `Waku`
# (ops in `waku/api/*`).
type KernelApi* = concept w
  # --- topic construction ---
  buildContentTopic(
    w, appName = string, appVersion = uint32, name = string, encoding = string
  ) is Future[Result[ContentTopic, string]]
  buildPubsubTopic(w, topicName = string) is Future[Result[PubsubTopic, string]]
  defaultPubsubTopic(w) is Future[Result[PubsubTopic, string]]

  # --- relay ---
  relayPublish(w, pubsubTopic = PubsubTopic, message = WakuMessage, timeoutMs = uint32) is
    Future[Result[string, string]]
  relaySubscribe(w, pubsubTopic = PubsubTopic) is Future[Result[bool, string]]
  relayUnsubscribe(w, pubsubTopic = PubsubTopic) is Future[Result[bool, string]]
  relayAddProtectedShard(w, clusterId = uint16, shardId = uint16, publicKey = string) is
    Future[Result[bool, string]]
  relayConnectedPeers(w, pubsubTopic = PubsubTopic) is
    Future[Result[seq[string], string]]
  relayPeersInMesh(w, pubsubTopic = PubsubTopic) is Future[Result[seq[string], string]]
  relayNumPeersInMesh(w, pubsubTopic = PubsubTopic) is Future[Result[int, string]]
  relayNumConnectedPeers(w, pubsubTopic = PubsubTopic) is Future[Result[int, string]]

  # --- filter ---
  filterSubscribe(
    w,
    pubsubTopic = PubsubTopic,
    contentTopics = seq[ContentTopic],
    pushHandler = FilterPushHandler,
  ) is Future[Result[bool, string]]
  filterUnsubscribe(w, pubsubTopic = PubsubTopic, contentTopics = seq[ContentTopic]) is
    Future[Result[bool, string]]
  filterUnsubscribeAll(w) is Future[Result[bool, string]]

  # --- lightpush ---
  lightpushPublish(w, pubsubTopic = PubsubTopic, message = WakuMessage) is
    Future[Result[string, string]]

  # --- store ---
  storeQuery(w, request = StoreQueryRequest, peer = string, timeoutMs = int) is
    Future[Result[StoreQueryResponse, string]]

  # --- peer management ---
  connect(w, peers = seq[string], timeoutMs = uint32) is Future[Result[bool, string]]
  disconnectPeerById(w, peerId = string) is Future[Result[bool, string]]
  disconnectAllPeers(w) is Future[Result[bool, string]]
  dialPeer(w, peerAddr = string, protocol = string, timeoutMs = int) is
    Future[Result[bool, string]]
  dialPeerById(w, peerId = string, protocol = string, timeoutMs = int) is
    Future[Result[bool, string]]
  peerIdsFromPeerstore(w) is Future[Result[seq[string], string]]
  connectedPeersInfo(w) is Future[Result[seq[PeerConnInfo], string]]
  connectedPeers(w) is Future[Result[seq[string], string]]
  peerIdsByProtocol(w, protocol = string) is Future[Result[seq[string], string]]

  # --- discovery ---
  dnsDiscovery(w, enrTreeUrl = string, nameServer = string, timeoutMs = int) is
    Future[Result[seq[string], string]]
  discv5UpdateBootnodes(w, bootnodes = string) is Future[Result[bool, string]]
  startDiscv5(w) is Future[Result[bool, string]]
  stopDiscv5(w) is Future[Result[bool, string]]
  peerExchangeRequest(w, numPeers = uint64) is Future[Result[int, string]]

  # --- debug / info ---
  version(w) is Future[Result[string, string]]
  listenAddresses(w) is Future[Result[seq[string], string]]
  myEnr(w) is Future[Result[string, string]]
  myPeerId(w) is Future[Result[string, string]]
  metrics(w) is Future[Result[string, string]]
  isOnline(w) is Future[Result[bool, string]]
  pingPeer(w, peerAddr = string, timeoutMs = int) is Future[Result[int64, string]]
