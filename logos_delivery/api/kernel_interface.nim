## KernelInterface — the libwaku operation set, exposed with the real Nim typed
## signatures behind each entry point (NOT the flat string/JSON FFI contract).
##
## WakuMessage / PubsubTopic / ContentTopic / StoreQueryRequest+Response cross
## the broker natively. libp2p identity / ENR values cross as their canonical
## string forms (they are ref/opaque and cannot be auto-serialised). Inbound
## relay/filter delivery is the `ReceivedMessage` event (replaces libwaku's
## set_event_callback for messages).
##
## Broker constraints (v3.1.0): every request returns `Result[T, string]` — the
## error channel is always `string`; the payload `T` must NOT be `void` (the mt
## codec cannot encode `void`), so "no value" requests return `Result[bool, string]`.

import std/options
import results, chronos
import brokers/broker_interface

import logos_delivery/api/types

import
  logos_delivery/waku/waku_core, # PubsubTopic
  logos_delivery/waku/waku_store/common # StoreQueryRequest, StoreQueryResponse

export types

BrokerInterface(KernelInterface):
  EventBroker:
    type ReceivedMessage = object
      ## Inbound relay/filter message delivery (replaces set_event_callback).
      pubsubTopic*: PubsubTopic
      message*: WakuMessage

  # --- topic construction ---
  RequestBroker:
    proc buildContentTopic(
      appName: string, appVersion: uint32, name: string, encoding: string
    ): Future[Result[ContentTopic, string]] {.async.}

  RequestBroker:
    proc buildPubsubTopic(
      topicName: string
    ): Future[Result[PubsubTopic, string]] {.async.}

  RequestBroker:
    proc defaultPubsubTopic(): Future[Result[PubsubTopic, string]] {.async.}

  # --- relay ---
  RequestBroker:
    proc relayPublish(
      pubsubTopic: PubsubTopic, message: WakuMessage, timeoutMs: uint32
    ): Future[Result[int, string]] {.async.}

  RequestBroker:
    proc relaySubscribe(
      pubsubTopic: PubsubTopic
    ): Future[Result[bool, string]] {.async.}

  RequestBroker:
    proc relayUnsubscribe(
      pubsubTopic: PubsubTopic
    ): Future[Result[bool, string]] {.async.}

  RequestBroker:
    proc relayAddProtectedShard(
      clusterId: uint16, shardId: uint16, publicKey: string
    ): Future[Result[bool, string]] {.async.}

  RequestBroker:
    proc relayConnectedPeers(
      pubsubTopic: PubsubTopic
    ): Future[Result[seq[string], string]] {.async.}

  RequestBroker:
    proc relayPeersInMesh(
      pubsubTopic: PubsubTopic
    ): Future[Result[seq[string], string]] {.async.}

  # --- filter ---
  RequestBroker:
    proc filterSubscribe(
      pubsubTopic: Option[PubsubTopic], contentTopics: seq[ContentTopic], peer: string
    ): Future[Result[bool, string]] {.async.}

  RequestBroker:
    proc filterUnsubscribe(
      pubsubTopic: Option[PubsubTopic], contentTopics: seq[ContentTopic], peer: string
    ): Future[Result[bool, string]] {.async.}

  RequestBroker:
    proc filterUnsubscribeAll(peer: string): Future[Result[bool, string]] {.async.}

  # --- lightpush ---
  RequestBroker:
    proc lightpushPublish(
      pubsubTopic: PubsubTopic, message: WakuMessage, peer: string
    ): Future[Result[string, string]] {.async.}

  # --- store ---
  RequestBroker:
    proc storeQuery(
      request: StoreQueryRequest, peer: string, timeoutMs: int
    ): Future[Result[StoreQueryResponse, string]] {.async.}

  # --- peer management ---
  RequestBroker:
    proc connect(
      peers: seq[string], timeoutMs: uint32
    ): Future[Result[bool, string]] {.async.}

  RequestBroker:
    proc disconnectPeerById(peerId: string): Future[Result[bool, string]] {.async.}

  RequestBroker:
    proc disconnectAllPeers(): Future[Result[bool, string]] {.async.}

  RequestBroker:
    proc dialPeer(
      peerAddr: string, protocol: string, timeoutMs: int
    ): Future[Result[bool, string]] {.async.}

  RequestBroker:
    proc dialPeerById(
      peerId: string, protocol: string, timeoutMs: int
    ): Future[Result[bool, string]] {.async.}

  RequestBroker:
    proc peerIdsFromPeerstore(): Future[Result[seq[string], string]] {.async.}

  RequestBroker:
    proc connectedPeersInfo(): Future[Result[seq[string], string]] {.async.}

  RequestBroker:
    proc connectedPeers(): Future[Result[seq[string], string]] {.async.}

  RequestBroker:
    proc peerIdsByProtocol(
      protocol: string
    ): Future[Result[seq[string], string]] {.async.}

  # --- discovery ---
  RequestBroker:
    proc dnsDiscovery(
      enrTreeUrl: string, nameServer: string, timeoutMs: int
    ): Future[Result[seq[string], string]] {.async.}

  RequestBroker:
    proc discv5UpdateBootnodes(
      bootnodes: seq[string]
    ): Future[Result[bool, string]] {.async.}

  RequestBroker:
    proc startDiscv5(): Future[Result[bool, string]] {.async.}

  RequestBroker:
    proc stopDiscv5(): Future[Result[bool, string]] {.async.}

  RequestBroker:
    proc peerExchangeRequest(numPeers: uint64): Future[Result[int, string]] {.async.}

  # --- debug / info ---
  RequestBroker:
    proc version(): Future[Result[string, string]] {.async.}

  RequestBroker:
    proc listenAddresses(): Future[Result[seq[string], string]] {.async.}

  RequestBroker:
    proc myEnr(): Future[Result[string, string]] {.async.}

  RequestBroker:
    proc myPeerId(): Future[Result[string, string]] {.async.}

  RequestBroker:
    proc metrics(): Future[Result[string, string]] {.async.}

  RequestBroker:
    proc isOnline(): Future[Result[bool, string]] {.async.}

  RequestBroker:
    proc pingPeer(
      peerAddr: string, timeoutMs: int
    ): Future[Result[int64, string]] {.async.}
