import std/options
import chronos, results
import brokers/event_broker

import logos_delivery/api/types as api_types
import logos_delivery/waku/waku_core/topics/pubsub_topic
import logos_delivery/waku/waku_core/message
import logos_delivery/waku/waku_store/common as store_types

export event_broker
export api_types, pubsub_topic, store_types

type IKernel* = ref object of RootObj

EventBroker:
  # Internal event emitted when a message arrives from the network via any protocol
  type MessageSeenEvent* = object
    topic*: PubsubTopic
    message*: WakuMessage

# --- topic construction ---
method buildContentTopic*(
    self: IKernel, appName: string, appVersion: uint32, name: string, encoding: string
): Future[Result[ContentTopic, string]] {.async: (raises: []), base.} =
  return err("Interface IKernel.buildContentTopic not implemented")

method buildPubsubTopic*(
    self: IKernel, topicName: string
): Future[Result[PubsubTopic, string]] {.async: (raises: []), base.} =
  return err("Interface IKernel.buildPubsubTopic not implemented")

method defaultPubsubTopic*(
    self: IKernel
): Future[Result[PubsubTopic, string]] {.async: (raises: []), base.} =
  return err("Interface IKernel.defaultPubsubTopic not implemented")

# --- relay ---
method relayPublish*(
    self: IKernel, pubsubTopic: PubsubTopic, message: WakuMessage, timeoutMs: uint32
): Future[Result[int, string]] {.async: (raises: []), base.} =
  return err("Interface IKernel.relayPublish not implemented")

method relaySubscribe*(
    self: IKernel, pubsubTopic: PubsubTopic
): Future[Result[bool, string]] {.async: (raises: []), base.} =
  return err("Interface IKernel.relaySubscribe not implemented")

method relayUnsubscribe*(
    self: IKernel, pubsubTopic: PubsubTopic
): Future[Result[bool, string]] {.async: (raises: []), base.} =
  return err("Interface IKernel.relayUnsubscribe not implemented")

method relayAddProtectedShard*(
    self: IKernel, clusterId: uint16, shardId: uint16, publicKey: string
): Future[Result[bool, string]] {.async: (raises: []), base.} =
  return err("Interface IKernel.relayAddProtectedShard not implemented")

method relayConnectedPeers*(
    self: IKernel, pubsubTopic: PubsubTopic
): Future[Result[seq[string], string]] {.async: (raises: []), base.} =
  return err("Interface IKernel.relayConnectedPeers not implemented")

method relayPeersInMesh*(
    self: IKernel, pubsubTopic: PubsubTopic
): Future[Result[seq[string], string]] {.async: (raises: []), base.} =
  return err("Interface IKernel.relayPeersInMesh not implemented")

# --- filter ---
method filterSubscribe*(
    self: IKernel,
    pubsubTopic: Option[PubsubTopic],
    contentTopics: seq[ContentTopic],
    peer: string,
): Future[Result[bool, string]] {.async: (raises: []), base.} =
  return err("Interface IKernel.filterSubscribe not implemented")

method filterUnsubscribe*(
    self: IKernel,
    pubsubTopic: Option[PubsubTopic],
    contentTopics: seq[ContentTopic],
    peer: string,
): Future[Result[bool, string]] {.async: (raises: []), base.} =
  return err("Interface IKernel.filterUnsubscribe not implemented")

method filterUnsubscribeAll*(
    self: IKernel, peer: string
): Future[Result[bool, string]] {.async: (raises: []), base.} =
  return err("Interface IKernel.filterUnsubscribeAll not implemented")

# --- lightpush ---
method lightpushPublish*(
    self: IKernel, pubsubTopic: PubsubTopic, message: WakuMessage, peer: string
): Future[Result[string, string]] {.async: (raises: []), base.} =
  return err("Interface IKernel.lightpushPublish not implemented")

# --- store ---
method storeQuery*(
    self: IKernel, request: StoreQueryRequest, peer: string, timeoutMs: int
): Future[Result[StoreQueryResponse, string]] {.async: (raises: []), base.} =
  return err("Interface IKernel.storeQuery not implemented")

# --- peer management ---
method connect*(
    self: IKernel, peers: seq[string], timeoutMs: uint32
): Future[Result[bool, string]] {.async: (raises: []), base.} =
  return err("Interface IKernel.connect not implemented")

method disconnectPeerById*(
    self: IKernel, peerId: string
): Future[Result[bool, string]] {.async: (raises: []), base.} =
  return err("Interface IKernel.disconnectPeerById not implemented")

method disconnectAllPeers*(
    self: IKernel
): Future[Result[bool, string]] {.async: (raises: []), base.} =
  return err("Interface IKernel.disconnectAllPeers not implemented")

method dialPeer*(
    self: IKernel, peerAddr: string, protocol: string, timeoutMs: int
): Future[Result[bool, string]] {.async: (raises: []), base.} =
  return err("Interface IKernel.dialPeer not implemented")

method dialPeerById*(
    self: IKernel, peerId: string, protocol: string, timeoutMs: int
): Future[Result[bool, string]] {.async: (raises: []), base.} =
  return err("Interface IKernel.dialPeerById not implemented")

method peerIdsFromPeerstore*(
    self: IKernel
): Future[Result[seq[string], string]] {.async: (raises: []), base.} =
  return err("Interface IKernel.peerIdsFromPeerstore not implemented")

method connectedPeersInfo*(
    self: IKernel
): Future[Result[seq[string], string]] {.async: (raises: []), base.} =
  return err("Interface IKernel.connectedPeersInfo not implemented")

method connectedPeers*(
    self: IKernel
): Future[Result[seq[string], string]] {.async: (raises: []), base.} =
  return err("Interface IKernel.connectedPeers not implemented")

method peerIdsByProtocol*(
    self: IKernel, protocol: string
): Future[Result[seq[string], string]] {.async: (raises: []), base.} =
  return err("Interface IKernel.peerIdsByProtocol not implemented")

# --- discovery ---
method dnsDiscovery*(
    self: IKernel, enrTreeUrl: string, nameServer: string, timeoutMs: int
): Future[Result[seq[string], string]] {.async: (raises: []), base.} =
  return err("Interface IKernel.dnsDiscovery not implemented")

method discv5UpdateBootnodes*(
    self: IKernel, bootnodes: seq[string]
): Future[Result[bool, string]] {.async: (raises: []), base.} =
  return err("Interface IKernel.discv5UpdateBootnodes not implemented")

method startDiscv5*(
    self: IKernel
): Future[Result[bool, string]] {.async: (raises: []), base.} =
  return err("Interface IKernel.startDiscv5 not implemented")

method stopDiscv5*(
    self: IKernel
): Future[Result[bool, string]] {.async: (raises: []), base.} =
  return err("Interface IKernel.stopDiscv5 not implemented")

method peerExchangeRequest*(
    self: IKernel, numPeers: uint64
): Future[Result[int, string]] {.async: (raises: []), base.} =
  return err("Interface IKernel.peerExchangeRequest not implemented")

# --- debug / info ---
method version*(
    self: IKernel
): Future[Result[string, string]] {.async: (raises: []), base.} =
  return err("Interface IKernel.version not implemented")

method listenAddresses*(
    self: IKernel
): Future[Result[seq[string], string]] {.async: (raises: []), base.} =
  return err("Interface IKernel.listenAddresses not implemented")

method myEnr*(
    self: IKernel
): Future[Result[string, string]] {.async: (raises: []), base.} =
  return err("Interface IKernel.myEnr not implemented")

method myPeerId*(
    self: IKernel
): Future[Result[string, string]] {.async: (raises: []), base.} =
  return err("Interface IKernel.myPeerId not implemented")

method metrics*(
    self: IKernel
): Future[Result[string, string]] {.async: (raises: []), base.} =
  return err("Interface IKernel.metrics not implemented")

method pingPeer*(
    self: IKernel, peerAddr: string, timeoutMs: int
): Future[Result[int64, string]] {.async: (raises: []), base.} =
  return err("Interface IKernel.pingPeer not implemented")
