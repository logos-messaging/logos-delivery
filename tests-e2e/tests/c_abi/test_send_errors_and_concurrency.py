import base64

from src.steps.common import StepsCommon
from src.node.wrappers_manager import WrapperManager
from src.node.wrapper_helpers import (
    EventCollector,
    assert_event_invariants,
    create_message_bindings,
    get_node_multiaddr,
    wait_for_connected,
    wait_for_propagated,
    wait_for_error,
)


# Payload above DefaultMaxWakuMessageSize (150KiB), so the relay publish
# rejects it instead of failing with NO_PEERS_TO_RELAY.
OVERSIZED_PAYLOAD_BYTES = 200 * 1024
ERROR_TIMEOUT_S = 30.0
MESSAGE_SIZE_EXCEEDED_MSG = "Message size exceeded"


class TestS13RelayHardFailureWithoutFallback(StepsCommon):
    """
    S13: relay path is reachable (a relay peer is connected, so the publish
    gets past NO_PEERS_TO_RELAY), but the relay publish fails for another
    reason. An oversized payload is used so the relay processor rejects the
    message immediately. No lightpush fallback is configured.
      - Expected: Ok(RequestId), then a message_error event.
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
                "portsShift": 1,
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
                assert send_result.is_ok(), f"send() must return Ok(RequestId), got: {send_result.err()}"

                request_id = send_result.ok_value
                assert request_id, "send() returned an empty RequestId"

                error_event = wait_for_error(
                    collector=sender_collector,
                    request_id=request_id,
                    timeout_s=ERROR_TIMEOUT_S,
                )
                assert error_event is not None, (
                    f"No message_error event within {ERROR_TIMEOUT_S}s from the " f"relay processor. Collected events: {sender_collector.events}"
                )
                assert error_event["requestId"] == request_id
                assert MESSAGE_SIZE_EXCEEDED_MSG in (error_event.get("error") or ""), (
                    f"Expected error to contain {MESSAGE_SIZE_EXCEEDED_MSG!r}.\n" f"Got: {error_event.get('error')!r}\n" f"Full event: {error_event}"
                )

                propagated = wait_for_propagated(sender_collector, request_id, timeout_s=0)
                assert propagated is None, f"Unexpected message_propagated event for a failed relay publish: {propagated}"

                assert_event_invariants(sender_collector, request_id)
