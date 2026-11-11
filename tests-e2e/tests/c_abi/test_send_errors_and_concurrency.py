import base64

from src.steps.common import StepsCommon
from src.libs.common import delay
from src.node.wrappers_manager import WrapperManager
from src.node.wrapper_helpers import (
    SEND_TOO_LARGE_MSG,
    EventCollector,
    create_message_bindings,
    get_node_multiaddr,
    wait_for_connected,
)


# Payload above DefaultMaxWakuMessageSize (150KiB), so the sender refuses it.
OVERSIZED_PAYLOAD_BYTES = 200 * 1024
NO_EVENT_OBSERVATION_S = 3.0
MESSAGE_SIZE_EXCEEDED_MSG = "Message size exceeded"


class TestS13RelayHardFailureWithoutFallback(StepsCommon):
    """
    S13: relay path is reachable (a relay peer is connected), but the
    message cannot go out. An oversized payload is used, so the sender
    refuses the message before it charges anything for it. No lightpush
    fallback is configured.
      - Expected: a TooLarge error from send(), and no event.
    """

    def test_s13_relay_hard_failure_without_fallback(self, node_config):
        sender_collector = EventCollector()

        node_config.update(
            {
                "relay": True,
                "numShardsInNetwork": 1,
            }
        )

        sender_result = WrapperManager.create_and_start(
            config=node_config,
            event_cb=sender_collector.event_callback,
        )
        assert sender_result.is_ok(), f"Failed to start sender: {sender_result.err()}"

        with sender_result.ok_value as sender_node:
            relay_config = {
                **node_config,
                "staticnodes": [get_node_multiaddr(sender_node)],
            }

            relay_result = WrapperManager.create_and_start(config=relay_config)
            assert relay_result.is_ok(), f"Failed to start relay peer: {relay_result.err()}"

            with relay_result.ok_value:
                # A connected relay peer means the publish gets past
                # NO_PEERS_TO_RELAY and actually reaches the relay processor.
                assert wait_for_connected(sender_collector) is not None, (
                    f"Sender did not reach Connected/PartiallyConnected. " f"Collected events: {sender_collector.events}"
                )

                oversized_payload = base64.b64encode(b"x" * OVERSIZED_PAYLOAD_BYTES).decode()
                message = create_message_bindings(
                    payload=oversized_payload,
                    contentTopic="/test/1/s13-relay-hard-failure/proto",
                )

                send_result = sender_node.send_message(message=message)
                assert send_result.is_err(), f"send() of an oversized message must return an error, got: {send_result.ok_value}"
                assert SEND_TOO_LARGE_MSG in send_result.err(), send_result.err()
                assert MESSAGE_SIZE_EXCEEDED_MSG in send_result.err(), (
                    f"Expected error to contain {MESSAGE_SIZE_EXCEEDED_MSG!r}.\n" f"Got: {send_result.err()!r}"
                )

                # A refused send gets no event.
                delay(NO_EVENT_OBSERVATION_S)
                message_events = [event for event in sender_collector.snapshot() if event.get("eventType", "").startswith("message_")]
                assert not message_events, f"Unexpected message events for a refused send: {message_events}"
