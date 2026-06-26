import chronos, results
import brokers/event_broker

import logos_delivery/api/types as api_types
import logos_delivery/waku/waku_core/topics/pubsub_topic
import logos_delivery/waku/waku_core/message
import logos_delivery/waku/waku_core/subscription/push_handler
import logos_delivery/waku/waku_store/common as store_types

export event_broker
export api_types, pubsub_topic, store_types

EventBroker:
  # Internal event emitted when a message arrives from the network via any protocol
  type MessageSeenEvent* = object
    topic*: PubsubTopic
    message*: WakuMessage

# Structural API contract for the Kernel surface, implemented by `Waku`
# (ops in `waku/api/*`).
type KernelApi* = concept w
  # --- topic construction ---
  buildContentTopic(w, string, uint32, string, string) is
    Future[Result[ContentTopic, string]]
  buildPubsubTopic(w, string) is Future[Result[PubsubTopic, string]]
  defaultPubsubTopic(w) is Future[Result[PubsubTopic, string]]

  # --- relay ---
  relayPublish(w, PubsubTopic, WakuMessage, uint32) is Future[Result[string, string]]
  relaySubscribe(w, PubsubTopic) is Future[Result[bool, string]]
  relayUnsubscribe(w, PubsubTopic) is Future[Result[bool, string]]
  relayAddProtectedShard(w, uint16, uint16, string) is Future[Result[bool, string]]
  relayConnectedPeers(w, PubsubTopic) is Future[Result[seq[string], string]]
  relayPeersInMesh(w, PubsubTopic) is Future[Result[seq[string], string]]
  relayNumPeersInMesh(w, PubsubTopic) is Future[Result[int, string]]
  relayNumConnectedPeers(w, PubsubTopic) is Future[Result[int, string]]

  # --- filter ---
  filterSubscribe(w, PubsubTopic, seq[ContentTopic], FilterPushHandler) is
    Future[Result[bool, string]]
  filterUnsubscribe(w, PubsubTopic, seq[ContentTopic]) is Future[Result[bool, string]]
  filterUnsubscribeAll(w) is Future[Result[bool, string]]

  # --- lightpush ---
  lightpushPublish(w, PubsubTopic, WakuMessage) is Future[Result[string, string]]

  # --- store ---
  storeQuery(w, StoreQueryRequest, string, int) is
    Future[Result[StoreQueryResponse, string]]

  # --- peer management ---
  connect(w, seq[string], uint32) is Future[Result[bool, string]]
  disconnectPeerById(w, string) is Future[Result[bool, string]]
  disconnectAllPeers(w) is Future[Result[bool, string]]
  dialPeer(w, string, string, int) is Future[Result[bool, string]]
  dialPeerById(w, string, string, int) is Future[Result[bool, string]]
  peerIdsFromPeerstore(w) is Future[Result[seq[string], string]]
  connectedPeersInfo(w) is Future[Result[seq[PeerConnInfo], string]]
  connectedPeers(w) is Future[Result[seq[string], string]]
  peerIdsByProtocol(w, string) is Future[Result[seq[string], string]]

  # --- discovery ---
  dnsDiscovery(w, string, string, int) is Future[Result[seq[string], string]]
  discv5UpdateBootnodes(w, string) is Future[Result[bool, string]]
  startDiscv5(w) is Future[Result[bool, string]]
  stopDiscv5(w) is Future[Result[bool, string]]
  peerExchangeRequest(w, uint64) is Future[Result[int, string]]

  # --- debug / info ---
  version(w) is Future[Result[string, string]]
  listenAddresses(w) is Future[Result[seq[string], string]]
  myEnr(w) is Future[Result[string, string]]
  myPeerId(w) is Future[Result[string, string]]
  metrics(w) is Future[Result[string, string]]
  isOnline(w) is Future[Result[bool, string]]
  pingPeer(w, string, int) is Future[Result[int64, string]]
