import brokers/event_broker
import logos_delivery/waku/[api/types, waku_core/message, waku_core/topics]

# TODO: This is a temporary solution to avoid extensive code changes at import sites,
#       due to the move of API facing events for interface level.
#       Final solution all sites shall utilize interface rather then direct event imports and emit.
from logos_delivery/api/messaging_client_interface import
  MessageSentEvent, MessageErrorEvent, MessagePropagatedEvent, MessageReceivedEvent
export
  types, MessageSentEvent, MessageErrorEvent, MessagePropagatedEvent,
  MessageReceivedEvent

EventBroker:
  # Internal event emitted when a message arrives from the network via any protocol
  type MessageSeenEvent* = object
    topic*: PubsubTopic
    message*: WakuMessage
