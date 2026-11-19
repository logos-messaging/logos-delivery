import base64
import pytest
from src.steps.common import StepsCommon
from src.libs.common import delay, to_base64
from src.libs.custom_logger import get_custom_logger
from src.node.wrappers_manager import WrapperManager
from src.node.wrapper_helpers import (
    DELIVERY_WINDOW_S,
    SEND_REFUSED_NOT_CONNECTED,
    SEND_REFUSED_TOO_LARGE,
    EventCollector,
    assert_event_invariants,
    assert_message_hash,
    assert_no_message_events,
    assert_send_refused,
    create_message_bindings,
    get_node_multiaddr,
    send_once_connected,
    wait_for_connected,
    wait_for_propagated,
    wait_for_sent,
    wait_for_error,
)
from tests.c_abi.conftest import build_node_config

logger = get_custom_logger(__name__)

PROPAGATED_TIMEOUT_S = 30.0
SENT_TIMEOUT_S = 10.0
NO_SENT_OBSERVATION_S = 5.0
SENT_AFTER_STORE_TIMEOUT_S = 60.0
OVERSIZED_PAYLOAD_BYTES = 200 * 1024
SERVICE_DOWN_SETTLE_S = 3.0
# A refused send gets no event; how long to watch for one.
NO_EVENT_OBSERVATION_S = 3.0


class TestS06CoreSenderRelayOnly(StepsCommon):
    """
    S06 — Core sender with relay peers only, no store.
    Sender has local relay enabled and is connected to one relay peer.
    Expected: send() returns Ok(messageHash), message_propagated event arrives,
    no message_sent (store disabled), no message_error.
    """

    def test_s06_relay_propagation_without_store(self, node_config):
        sender_collector = EventCollector()

        node_config.update(
            {
                "relay": True,
                "store": False,
                "lightpush": False,
                "filter": False,
                "discv5Discovery": False,
                "numShardsInNetwork": 1,
                "reliabilityEnabled": True,
            }
        )

        sender_result = WrapperManager.create_and_start(
            config=node_config,
            event_cb=sender_collector.event_callback,
        )
        assert sender_result.is_ok(), f"Failed to start sender: {sender_result.err()}"

        with sender_result.ok_value as sender:
            peer_config = {
                **node_config,
                "staticnodes": [get_node_multiaddr(sender)],
            }

            peer_result = WrapperManager.create_and_start(config=peer_config)
            assert peer_result.is_ok(), f"Failed to start relay peer: {peer_result.err()}"

            with peer_result.ok_value:
                assert wait_for_connected(sender_collector) is not None, "Sender did not reach Connected/PartiallyConnected state"

                message = create_message_bindings(
                    payload=to_base64("S06 relay-only test payload"),
                    contentTopic="/test/1/s06-relay-only/proto",
                )

                send_result = sender.send_message(message=message)
                message_hash = assert_message_hash(send_result)

                propagated = wait_for_propagated(
                    collector=sender_collector,
                    message_hash=message_hash,
                    timeout_s=PROPAGATED_TIMEOUT_S,
                )
                assert propagated is not None, (
                    f"No message_propagated event within {PROPAGATED_TIMEOUT_S}s. " f"Collected events: {sender_collector.events}"
                )
                assert propagated["messageHash"] == message_hash

                error = wait_for_error(sender_collector, message_hash, timeout_s=0)
                assert error is None, f"Unexpected message_error event: {error}"

                sent = wait_for_sent(sender_collector, message_hash, timeout_s=0)
                assert sent is None, f"Unexpected message_sent event (store is disabled): {sent}"

                assert_event_invariants(sender_collector, message_hash)


class TestS07CoreSenderRelayAndStore(StepsCommon):
    """
    S07 — Core sender with relay peers and store peer, reliability enabled.
    Sender relays message to a store-capable peer; delivery service validates
    the message reached the store via p2p reliability check.
    Expected: Propagated, then Sent.
    """

    def test_s07_relay_propagation_with_store_validation(self, node_config):
        sender_collector = EventCollector()

        node_config.update(
            {
                "relay": True,
                "store": False,
                "lightpush": False,
                "filter": False,
                "discv5Discovery": False,
                "numShardsInNetwork": 1,
                "reliabilityEnabled": True,
            }
        )

        sender_result = WrapperManager.create_and_start(
            config=node_config,
            event_cb=sender_collector.event_callback,
        )
        assert sender_result.is_ok(), f"Failed to start sender: {sender_result.err()}"

        with sender_result.ok_value as sender:
            peer_config = {
                **node_config,
                "staticnodes": [get_node_multiaddr(sender)],
                "store": True,
            }

            peer_result = WrapperManager.create_and_start(config=peer_config)
            assert peer_result.is_ok(), f"Failed to start store peer: {peer_result.err()}"

            with peer_result.ok_value:
                assert wait_for_connected(sender_collector) is not None, "Sender did not reach Connected/PartiallyConnected state"

                message = create_message_bindings(
                    payload=to_base64("S07 relay+store test payload"),
                    contentTopic="/test/1/s07-relay-store/proto",
                )

                send_result = sender.send_message(message=message)
                message_hash = assert_message_hash(send_result)

                propagated = wait_for_propagated(
                    collector=sender_collector,
                    message_hash=message_hash,
                    timeout_s=PROPAGATED_TIMEOUT_S,
                )
                assert propagated is not None, (
                    f"No message_propagated event within {PROPAGATED_TIMEOUT_S}s. " f"Collected events: {sender_collector.events}"
                )
                assert propagated["messageHash"] == message_hash

                sent = wait_for_sent(
                    collector=sender_collector,
                    message_hash=message_hash,
                    timeout_s=SENT_TIMEOUT_S,
                )
                assert sent is not None, (
                    f"No message_sent event within {SENT_TIMEOUT_S}s after propagation. " f"Collected events: {sender_collector.events}"
                )
                assert sent["messageHash"] == message_hash

                error = wait_for_error(sender_collector, message_hash, timeout_s=0)
                assert error is None, f"Unexpected message_error event: {error}"

                assert_event_invariants(sender_collector, message_hash)


class TestRelayToLightpushFallback(StepsCommon):
    """S08/S09 — Relay-to-lightpush fallback.

    Sender has relay enabled but zero gossipsub relay peers.
    A lightpush peer is reachable via lightpushnode (no staticnodes).
    Relay fails with NO_PEERS_TO_RELAY, lightpush fallback succeeds
    in the same processing pass.

    Topology:
        [Service]    relay=True, lightpush=True
        [RelayPeer]  relay=True, staticnodes=[service]  (gives service gossipsub mesh)
        [Sender]     relay=True, lightpush=True, lightpushnode=service
                     (no staticnodes → zero gossipsub relay peers → fallback)
    """

    def test_s08_relay_fallback_to_lightpush(self, node_config):
        """S08: no store peer → Propagated only."""
        sender_collector = EventCollector()

        node_config.update(
            {
                "relay": True,
                "lightpush": True,
                "store": False,
                "filter": False,
                "discv5Discovery": False,
                "numShardsInNetwork": 1,
            }
        )

        service_result = WrapperManager.create_and_start(config=node_config)
        assert service_result.is_ok(), f"Failed to start service: {service_result.err()}"

        with service_result.ok_value as service:
            service_addr = get_node_multiaddr(service)

            relay_config = {
                **node_config,
                "lightpush": False,
                "staticnodes": [service_addr],
            }
            relay_result = WrapperManager.create_and_start(config=relay_config)
            assert relay_result.is_ok(), f"Failed to start relay peer: {relay_result.err()}"

            with relay_result.ok_value:
                sender_config = {
                    **node_config,
                    "lightpushnode": service_addr,
                }
                sender_result = WrapperManager.create_and_start(
                    config=sender_config,
                    event_cb=sender_collector.event_callback,
                )
                assert sender_result.is_ok(), f"Failed to start sender: {sender_result.err()}"

                with sender_result.ok_value as sender:
                    message = create_message_bindings()
                    send_result = send_once_connected(sender, message)
                    message_hash = assert_message_hash(send_result)

                    propagated = wait_for_propagated(
                        collector=sender_collector,
                        message_hash=message_hash,
                        timeout_s=PROPAGATED_TIMEOUT_S,
                    )
                    assert propagated is not None, (
                        f"No message_propagated event within {PROPAGATED_TIMEOUT_S}s. " f"Collected events: {sender_collector.events}"
                    )
                    assert propagated["messageHash"] == message_hash

                    error = wait_for_error(sender_collector, message_hash, timeout_s=0)
                    assert error is None, f"Unexpected message_error event: {error}"

                    sent = wait_for_sent(sender_collector, message_hash, timeout_s=0)
                    assert sent is None, f"Unexpected message_sent event (no store peer): {sent}"

                    assert_event_invariants(sender_collector, message_hash)

    def test_s09_relay_fallback_to_lightpush_with_store_validation(self, node_config):
        """S09: S08 + store peer + reliability → Propagated, then Sent."""
        sender_collector = EventCollector()

        node_config.update(
            {
                "relay": True,
                "lightpush": True,
                "store": True,
                "filter": False,
                "discv5Discovery": False,
                "numShardsInNetwork": 1,
            }
        )

        service_result = WrapperManager.create_and_start(config=node_config)
        assert service_result.is_ok(), f"Failed to start service: {service_result.err()}"

        with service_result.ok_value as service:
            service_addr = get_node_multiaddr(service)

            relay_config = {
                **node_config,
                "lightpush": False,
                "store": False,
                "staticnodes": [service_addr],
            }
            relay_result = WrapperManager.create_and_start(config=relay_config)
            assert relay_result.is_ok(), f"Failed to start relay peer: {relay_result.err()}"

            with relay_result.ok_value:
                sender_config = {**node_config, "reliabilityEnabled": True, "storenode": service_addr, "store": False}
                sender_result = WrapperManager.create_and_start(
                    config=sender_config,
                    event_cb=sender_collector.event_callback,
                )
                assert sender_result.is_ok(), f"Failed to start sender: {sender_result.err()}"

                with sender_result.ok_value as sender:
                    message = create_message_bindings()
                    send_result = send_once_connected(sender, message)
                    message_hash = assert_message_hash(send_result)

                    propagated = wait_for_propagated(
                        collector=sender_collector,
                        message_hash=message_hash,
                        timeout_s=PROPAGATED_TIMEOUT_S,
                    )
                    assert propagated is not None, (
                        f"No message_propagated event within {PROPAGATED_TIMEOUT_S}s. " f"Collected events: {sender_collector.events}"
                    )
                    assert propagated["messageHash"] == message_hash

                    sent = wait_for_sent(
                        collector=sender_collector,
                        message_hash=message_hash,
                        timeout_s=SENT_AFTER_STORE_TIMEOUT_S,
                    )
                    assert sent is not None, (
                        f"No message_sent event within {SENT_AFTER_STORE_TIMEOUT_S}s "
                        f"after propagation. Collected events: {sender_collector.events}"
                    )
                    assert sent["messageHash"] == message_hash

                    error = wait_for_error(sender_collector, message_hash, timeout_s=0)
                    assert error is None, f"Unexpected message_error event: {error}"

                    assert_event_invariants(sender_collector, message_hash)


class TestS10EdgeSenderLightpushOnly(StepsCommon):
    """
    S10 — Edge sender with lightpush path only, no store peer.
    Edge sender has no local relay; it publishes via a lightpush service node.
    Expected: Propagated only (no Sent, no Error).
    """

    def test_s10_edge_lightpush_propagation(self, node_config):
        sender_collector = EventCollector()

        common = {
            "store": False,
            "filter": False,
            "discv5Discovery": False,
            "numShardsInNetwork": 1,
        }

        service_config = build_node_config(relay=True, lightpush=True, **common)

        service_result = WrapperManager.create_and_start(config=service_config)
        assert service_result.is_ok(), f"Failed to start service node: {service_result.err()}"

        with service_result.ok_value as service_node:
            service_multiaddr = get_node_multiaddr(service_node)

            relay_config = build_node_config(
                relay=True,
                staticnodes=[service_multiaddr],
                **common,
            )

            relay_result = WrapperManager.create_and_start(config=relay_config)
            assert relay_result.is_ok(), f"Failed to start relay peer: {relay_result.err()}"

            with relay_result.ok_value:
                edge_config = build_node_config(
                    mode="Edge",
                    relay=False,
                    staticnodes=[service_multiaddr],
                    **common,
                )

                edge_result = WrapperManager.create_and_start(
                    config=edge_config,
                    event_cb=sender_collector.event_callback,
                )
                assert edge_result.is_ok(), f"Failed to start edge sender: {edge_result.err()}"

                with edge_result.ok_value as edge_sender:
                    message = create_message_bindings(
                        payload=to_base64("S10 edge lightpush test payload"),
                        contentTopic="/test/1/s10-edge-lightpush/proto",
                    )

                    send_result = send_once_connected(edge_sender, message)
                    message_hash = assert_message_hash(send_result)

                    propagated = wait_for_propagated(
                        collector=sender_collector,
                        message_hash=message_hash,
                        timeout_s=PROPAGATED_TIMEOUT_S,
                    )
                    assert propagated is not None, (
                        f"No message_propagated event within {PROPAGATED_TIMEOUT_S}s. " f"Collected events: {sender_collector.events}"
                    )
                    assert propagated["messageHash"] == message_hash

                    sent = wait_for_sent(sender_collector, message_hash, timeout_s=NO_SENT_OBSERVATION_S)
                    assert sent is None, f"Unexpected message_sent event (no store peer): {sent}"

                    error = wait_for_error(sender_collector, message_hash, timeout_s=0)
                    assert error is None, f"Unexpected message_error event: {error}"

                    assert_event_invariants(sender_collector, message_hash)


class TestS12IsolatedSenderNoPeers(StepsCommon):
    """
    S12 — Isolated sender, no peers.
    Sender has relay enabled but zero relay peers and zero lightpush peers,
    so its connection status is Disconnected.
    Expected: send() is refused with NotConnected, and the message gets no event.
    """

    def test_s12_send_with_no_peers_is_refused(self, node_config):
        sender_collector = EventCollector()

        node_config.update(
            {
                "relay": True,
                "store": False,
                "lightpush": False,
                "filter": False,
                "discv5Discovery": False,
                "numShardsInNetwork": 1,
            }
        )

        sender_result = WrapperManager.create_and_start(
            config=node_config,
            event_cb=sender_collector.event_callback,
        )
        assert sender_result.is_ok(), f"Failed to start sender: {sender_result.err()}"

        with sender_result.ok_value as sender:
            message = create_message_bindings(
                payload=to_base64("S12 isolated sender payload"),
                contentTopic="/test/1/s12-isolated/proto",
            )

            send_result = sender.send_message(message=message)
            assert_send_refused(send_result, SEND_REFUSED_NOT_CONNECTED)

            assert_no_message_events(sender_collector, NO_EVENT_OBSERVATION_S)


class TestS14OversizedMessageRefused(StepsCommon):
    """
    S14 — Oversized message.
    Edge sender sends a message exceeding DefaultMaxWakuMessageSize (150KiB).
    send() checks the size, with the RLN proof, before any network attempt.
    Expected: send() is refused with TooLarge, and the message gets no event.
    """

    def test_s14_oversized_message_is_refused(self):
        sender_collector = EventCollector()

        common = {
            "store": False,
            "filter": False,
            "discv5Discovery": False,
            "numShardsInNetwork": 1,
        }

        service_config = build_node_config(relay=True, lightpush=True, **common)
        service_result = WrapperManager.create_and_start(config=service_config)
        assert service_result.is_ok(), f"Failed to start service: {service_result.err()}"

        with service_result.ok_value as service:
            service_multiaddr = get_node_multiaddr(service)

            edge_config = build_node_config(
                mode="Edge",
                relay=False,
                staticnodes=[service_multiaddr],
                **common,
            )
            edge_result = WrapperManager.create_and_start(
                config=edge_config,
                event_cb=sender_collector.event_callback,
            )
            assert edge_result.is_ok(), f"Failed to start edge sender: {edge_result.err()}"

            with edge_result.ok_value as edge_sender:
                oversized_payload = base64.b64encode(b"x" * OVERSIZED_PAYLOAD_BYTES).decode()
                message = create_message_bindings(
                    payload=oversized_payload,
                    contentTopic="/test/1/s14-oversized/proto",
                )

                # Retried until the edge has a peer, so the refusal comes from the size check.
                send_result = send_once_connected(edge_sender, message)
                error = assert_send_refused(send_result, SEND_REFUSED_TOO_LARGE)
                assert "exceeds the maximum message size" in error, f"Error doesn't indicate a size violation: {error!r}"

                assert_no_message_events(sender_collector, NO_EVENT_OBSERVATION_S)


class TestS15LightpushRetryableErrorRecovery(StepsCommon):
    """
    S15 — Lightpush retryable error + recovery.
    Edge sender publishes via a lightpush service node that has NO relay peers.
    The service accepts the lightpush request but returns NO_PEERS_TO_RELAY —
    a retryable error (explicitly listed in the S15 spec).  The message enters
    the retry loop.  A relay peer then joins the service node, and a retry
    within the delivery window succeeds.
    Expected: send() returns Ok(messageHash), then Propagated within the delivery window.
    """

    def test_s15_lightpush_retryable_error_then_recovery(self):
        sender_collector = EventCollector()

        common = {
            "store": False,
            "filter": False,
            "discv5Discovery": False,
            "numShardsInNetwork": 1,
        }

        service_config = build_node_config(relay=True, lightpush=True, **common)
        service_result = WrapperManager.create_and_start(config=service_config)
        assert service_result.is_ok(), f"Failed to start service: {service_result.err()}"

        with service_result.ok_value as service:
            service_multiaddr = get_node_multiaddr(service)

            edge_config = build_node_config(
                mode="Edge",
                relay=False,
                staticnodes=[service_multiaddr],
                **common,
            )
            edge_result = WrapperManager.create_and_start(
                config=edge_config,
                event_cb=sender_collector.event_callback,
            )
            assert edge_result.is_ok(), f"Failed to start edge sender: {edge_result.err()}"

            with edge_result.ok_value as edge_sender:
                msg = create_message_bindings(
                    payload=to_base64("S15 retryable error recovery"),
                    contentTopic="/test/1/s15-recovery/proto",
                )
                send_result = send_once_connected(edge_sender, msg)
                message_hash = assert_message_hash(send_result)

                delay(SERVICE_DOWN_SETTLE_S)

                early_propagated = wait_for_propagated(sender_collector, message_hash, timeout_s=0)
                assert early_propagated is None, (
                    f"message_propagated arrived before relay peer joined — " f"retryable error path was not exercised: {early_propagated}"
                )

                relay_config = build_node_config(
                    relay=True,
                    staticnodes=[service_multiaddr],
                    **common,
                )
                relay_result = WrapperManager.create_and_start(config=relay_config)
                assert relay_result.is_ok(), f"Failed to start relay peer: {relay_result.err()}"

                with relay_result.ok_value:
                    # The task fails once the delivery window from the message timestamp ends.
                    propagated = wait_for_propagated(
                        collector=sender_collector,
                        message_hash=message_hash,
                        timeout_s=DELIVERY_WINDOW_S,
                    )
                    assert propagated is not None, (
                        f"No message_propagated within the {DELIVERY_WINDOW_S}s delivery window "
                        f"after relay peer joined. "
                        f"Collected events: {sender_collector.events}"
                    )
                    assert propagated["messageHash"] == message_hash

                    error = wait_for_error(sender_collector, message_hash, timeout_s=0)
                    assert error is None, f"Unexpected message_error after recovery: {error}"

                    assert_event_invariants(sender_collector, message_hash)
