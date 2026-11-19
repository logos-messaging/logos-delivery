import base64

from src.steps.common import StepsCommon
from src.node.wrappers_manager import WrapperManager
from src.node.wrapper_helpers import (
    SEND_REFUSED_TOO_LARGE,
    EventCollector,
    assert_no_message_events,
    assert_send_refused,
    create_message_bindings,
    get_node_multiaddr,
    wait_for_connected,
)


# Payload above DefaultMaxWakuMessageSize (150KiB).
OVERSIZED_PAYLOAD_BYTES = 200 * 1024
# A refused send gets no event; how long to watch for one.
NO_EVENT_OBSERVATION_S = 3.0
MESSAGE_SIZE_EXCEEDED_MSG = "exceeds the maximum message size"


class TestS13RelayHardFailureWithoutFallback(StepsCommon):
    """
    S13: relay path is reachable (a relay peer is connected), but the message
    is larger than the maximum message size. send() checks the size, with the
    RLN proof, before any network attempt. No lightpush fallback is configured.
      - Expected: send() is refused with TooLarge, and the message gets no event.
    """

    def test_s13_oversized_message_is_refused(self, node_config):
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
                # Connected, so the refusal comes from the size check and not from the connection check.
                assert wait_for_connected(sender_collector) is not None, (
                    f"Sender did not reach Connected/PartiallyConnected. " f"Collected events: {sender_collector.events}"
                )

                oversized_payload = base64.b64encode(b"x" * OVERSIZED_PAYLOAD_BYTES).decode()
                message = create_message_bindings(
                    payload=oversized_payload,
                    contentTopic="/test/1/s13-relay-hard-failure/proto",
                )

                send_result = sender_node.send_message(message=message)
                error = assert_send_refused(send_result, SEND_REFUSED_TOO_LARGE)
                assert MESSAGE_SIZE_EXCEEDED_MSG in error, f"Expected error to contain {MESSAGE_SIZE_EXCEEDED_MSG!r}, got: {error!r}"

                assert_no_message_events(sender_collector, NO_EVENT_OBSERVATION_S)
