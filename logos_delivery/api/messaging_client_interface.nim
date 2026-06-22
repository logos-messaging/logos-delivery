## MessagingClientInterface — the messaging API (waku/api) minus createNode.
##
## Node creation lives in the facade (LogosDeliveryInterface); this interface exposes
## subscribe / unsubscribe / send only.

import results, chronos
import brokers/broker_interface

import logos_delivery/api/types
export types

BrokerInterface(MessagingClientInterface):
  EventBroker:
    # Event emitted when a message is sent to the network
    type MessageSentEvent* = object
      requestId*: RequestId
      messageHash*: string

  EventBroker:
    # Event emitted when a message send operation fails
    type MessageErrorEvent* = object
      requestId*: RequestId
      messageHash*: string
      error*: string

  EventBroker:
    # Confirmation that a message has been correctly delivered to some neighbouring nodes.
    type MessagePropagatedEvent* = object
      requestId*: RequestId
      messageHash*: string

  EventBroker:
    # Event emitted when a message is received via Waku
    type MessageReceivedEvent* = object
      messageHash*: string
      message*: WakuMessage

  RequestBroker:
    proc subscribe(contentTopic: ContentTopic): Future[Result[void, string]] {.async.}

  RequestBroker:
    proc unsubscribe(contentTopic: ContentTopic): Future[Result[void, string]] {.async.}

  RequestBroker:
    # Returns the RequestId in its string form. Named `sendMessage` (not `send`)
    # because broker request verbs must be globally unique across all interfaces
    # in the library, and ReliableChannelManagerInterface also has a send.
    proc send(envelope: MessageEnvelope): Future[Result[RequestId, string]] {.async.}
