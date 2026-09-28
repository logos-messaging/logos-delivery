import base64
import pytest
from src.steps.common import StepsCommon
from src.libs.common import delay, to_base64
from src.libs.custom_logger import get_custom_logger
from src.node.wrappers_manager import WrapperManager
from src.node.wrapper_helpers import (
    EventCollector,
    assert_event_invariants,
    create_message_bindings,
    get_node_multiaddr,
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
RECOVERY_TIMEOUT_S = 45.0
SERVICE_DOWN_SETTLE_S = 3.0

# MaxTimeInCache from send_service.nim.
MAX_TIME_IN_CACHE_S = 60.0
# Extra slack to cover the background retry loop tick after the window expires.
CACHE_EXPIRY_SLACK_S = 10.0
ERROR_AFTER_CACHE_EXPIRY_TIMEOUT_S = MAX_TIME_IN_CACHE_S + CACHE_EXPIRY_SLACK_S
RETRY_WINDOW_EXPIRED_MSG = "Unable to send within retry time window"


class TestS02AutoSubscribeOnFirstSend(StepsCommon):
    """
    S02 — Auto-subscribe on first send.
    Sender never calls subscribe_content_topic() before send().
    The send API must auto-subscribe to the content topic used in the message.
    Expected: send() returns Ok(RequestId), message_propagated arrives.
    """

    def test_s02_send_without_explicit_subscribe(self, node_config):
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
            peer_config = {
                **node_config,
                "staticnodes": [get_node_multiaddr(sender)],
            }

            peer_result = WrapperManager.create_and_start(config=peer_config)
            assert peer_result.is_ok(), f"Failed to start relay peer: {peer_result.err()}"

            with peer_result.ok_value:
                assert wait_for_connected(sender_collector) is not None, "Sender did not reach Connected/PartiallyConnected state"

                message = create_message_bindings(
                    payload=to_base64("S02 auto-subscribe test payload"),
                    contentTopic="/test/1/s02-auto-subscribe/proto",
                )

                send_result = sender.send_message(message=message)
                assert send_result.is_ok(), f"send() failed: {send_result.err()}"

                request_id = send_result.ok_value
                assert request_id, "send() returned an empty RequestId"

                propagated = wait_for_propagated(
                    collector=sender_collector,
                    request_id=request_id,
                    timeout_s=PROPAGATED_TIMEOUT_S,
                )
                assert propagated is not None, (
                    f"No message_propagated event within {PROPAGATED_TIMEOUT_S}s. " f"Collected events: {sender_collector.events}"
                )
                assert propagated["requestId"] == request_id

                error = wait_for_error(sender_collector, request_id, timeout_s=0)
                assert error is None, f"Unexpected message_error event: {error}"


class TestS06CoreSenderRelayOnly(StepsCommon):
    """
    S06 — Core sender with relay peers only, no store.
    Sender has local relay enabled and is connected to one relay peer.
    Expected: send() returns Ok(RequestId), message_propagated event arrives,
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
                assert send_result.is_ok(), f"send() failed: {send_result.err()}"

                request_id = send_result.ok_value
                assert request_id, "send() returned an empty RequestId"

                propagated = wait_for_propagated(
                    collector=sender_collector,
                    request_id=request_id,
                    timeout_s=PROPAGATED_TIMEOUT_S,
                )
                assert propagated is not None, (
                    f"No message_propagated event within {PROPAGATED_TIMEOUT_S}s. " f"Collected events: {sender_collector.events}"
                )
                assert propagated["requestId"] == request_id

                error = wait_for_error(sender_collector, request_id, timeout_s=0)
                assert error is None, f"Unexpected message_error event: {error}"

                sent = wait_for_sent(sender_collector, request_id, timeout_s=0)
                assert sent is None, f"Unexpected message_sent event (store is disabled): {sent}"

                assert_event_invariants(sender_collector, request_id)


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
                message = create_message_bindings(
                    payload=to_base64("S07 relay+store test payload"),
                    contentTopic="/test/1/s07-relay-store/proto",
                )

                send_result = sender.send_message(message=message)
                assert send_result.is_ok(), f"send() failed: {send_result.err()}"

                request_id = send_result.ok_value
                assert request_id, "send() returned an empty RequestId"

                propagated = wait_for_propagated(
                    collector=sender_collector,
                    request_id=request_id,
                    timeout_s=PROPAGATED_TIMEOUT_S,
                )
                assert propagated is not None, (
                    f"No message_propagated event within {PROPAGATED_TIMEOUT_S}s. " f"Collected events: {sender_collector.events}"
                )
                assert propagated["requestId"] == request_id

                sent = wait_for_sent(
                    collector=sender_collector,
                    request_id=request_id,
                    timeout_s=SENT_TIMEOUT_S,
                )
                assert sent is not None, (
                    f"No message_sent event within {SENT_TIMEOUT_S}s after propagation. " f"Collected events: {sender_collector.events}"
                )
                assert sent["requestId"] == request_id

                error = wait_for_error(sender_collector, request_id, timeout_s=0)
                assert error is None, f"Unexpected message_error event: {error}"

                assert_event_invariants(sender_collector, request_id)


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
                    send_result = sender.send_message(message=message)
                    assert send_result.is_ok(), f"send() failed: {send_result.err()}"

                    request_id = send_result.ok_value
                    assert request_id, "send() returned an empty RequestId"

                    propagated = wait_for_propagated(
                        collector=sender_collector,
                        request_id=request_id,
                        timeout_s=PROPAGATED_TIMEOUT_S,
                    )
                    assert propagated is not None, (
                        f"No message_propagated event within {PROPAGATED_TIMEOUT_S}s. " f"Collected events: {sender_collector.events}"
                    )
                    assert propagated["requestId"] == request_id

                    error = wait_for_error(sender_collector, request_id, timeout_s=0)
                    assert error is None, f"Unexpected message_error event: {error}"

                    sent = wait_for_sent(sender_collector, request_id, timeout_s=0)
                    assert sent is None, f"Unexpected message_sent event (no store peer): {sent}"

                    assert_event_invariants(sender_collector, request_id)

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
                    send_result = sender.send_message(message=message)
                    assert send_result.is_ok(), f"send() failed: {send_result.err()}"

                    request_id = send_result.ok_value
                    assert request_id, "send() returned an empty RequestId"

                    propagated = wait_for_propagated(
                        collector=sender_collector,
                        request_id=request_id,
                        timeout_s=PROPAGATED_TIMEOUT_S,
                    )
                    assert propagated is not None, (
                        f"No message_propagated event within {PROPAGATED_TIMEOUT_S}s. " f"Collected events: {sender_collector.events}"
                    )
                    assert propagated["requestId"] == request_id

                    sent = wait_for_sent(
                        collector=sender_collector,
                        request_id=request_id,
                        timeout_s=SENT_AFTER_STORE_TIMEOUT_S,
                    )
                    assert sent is not None, (
                        f"No message_sent event within {SENT_AFTER_STORE_TIMEOUT_S}s "
                        f"after propagation. Collected events: {sender_collector.events}"
                    )
                    assert sent["requestId"] == request_id

                    error = wait_for_error(sender_collector, request_id, timeout_s=0)
                    assert error is None, f"Unexpected message_error event: {error}"

                    assert_event_invariants(sender_collector, request_id)


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

                    send_result = edge_sender.send_message(message=message)
                    assert send_result.is_ok(), f"send() failed: {send_result.err()}"

                    request_id = send_result.ok_value
                    assert request_id, "send() returned an empty RequestId"

                    propagated = wait_for_propagated(
                        collector=sender_collector,
                        request_id=request_id,
                        timeout_s=PROPAGATED_TIMEOUT_S,
                    )
                    assert propagated is not None, (
                        f"No message_propagated event within {PROPAGATED_TIMEOUT_S}s. " f"Collected events: {sender_collector.events}"
                    )
                    assert propagated["requestId"] == request_id

                    sent = wait_for_sent(sender_collector, request_id, timeout_s=NO_SENT_OBSERVATION_S)
                    assert sent is None, f"Unexpected message_sent event (no store peer): {sent}"

                    error = wait_for_error(sender_collector, request_id, timeout_s=0)
                    assert error is None, f"Unexpected message_error event: {error}"

                    assert_event_invariants(sender_collector, request_id)


class TestS12IsolatedSenderNoPeers(StepsCommon):
    """
    S12 — Isolated sender, no peers.
    Sender has relay enabled but zero relay peers and zero lightpush peers.
    Expected: send() returns Ok(RequestId), but eventually a message_error
    event arrives (no route to propagate).
    """

    def test_s12_send_with_no_peers_produces_error(self, node_config):
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
            assert send_result.is_ok(), f"send() must return Ok(RequestId) even with no peers, got: {send_result.err()}"

            request_id = send_result.ok_value
            assert request_id, "send() returned an empty RequestId"

            error = wait_for_error(
                collector=sender_collector,
                request_id=request_id,
                timeout_s=ERROR_AFTER_CACHE_EXPIRY_TIMEOUT_S,
            )
            assert error is not None, (
                f"No message_error event within {ERROR_AFTER_CACHE_EXPIRY_TIMEOUT_S}s "
                f"(MaxTimeInCache={MAX_TIME_IN_CACHE_S}s + slack) for isolated sender. "
                f"Collected events: {sender_collector.events}"
            )
            assert error["requestId"] == request_id

            propagated = wait_for_propagated(sender_collector, request_id, timeout_s=0)
            assert propagated is None, f"Unexpected message_propagated event for isolated sender: {propagated}"


class TestS14LightpushNonRetryableError(StepsCommon):
    """
    S14 — Lightpush non-retryable error via oversized message.
    Edge sender publishes a message exceeding DefaultMaxWakuMessageSize (150KiB)
    through a lightpush service node. The server validates message size and
    returns INVALID_MESSAGE (420), a non-retryable error.
    Expected: send() returns Ok(RequestId), then message_error event.
    """

    def test_s14_oversized_message_triggers_error(self):
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

                send_result = edge_sender.send_message(message=message)
                assert send_result.is_ok(), f"send() failed: {send_result.err()}"

                request_id = send_result.ok_value
                assert request_id, "send() returned an empty RequestId"

                error = wait_for_error(
                    collector=sender_collector,
                    request_id=request_id,
                    timeout_s=PROPAGATED_TIMEOUT_S,
                )
                assert error is not None, (
                    f"No message_error event within {PROPAGATED_TIMEOUT_S}s "
                    f"after sending oversized message. "
                    f"Collected events: {sender_collector.events}"
                )
                assert error["requestId"] == request_id
                logger.info(f"S14 received error event: {error}")

                error_msg = error.get("error", "").lower()
                assert "size exceeded" in error_msg, f"Error message doesn't indicate size violation: {error}"

                propagated = wait_for_propagated(sender_collector, request_id, timeout_s=0)
                assert propagated is None, f"Unexpected message_propagated for an invalid message: {propagated}"

                assert_event_invariants(sender_collector, request_id)


class TestS15LightpushRetryableErrorRecovery(StepsCommon):
    """
    S15 — Lightpush retryable error + recovery.
    Edge sender publishes via a lightpush service node that has NO relay peers.
    The service accepts the lightpush request but returns NO_PEERS_TO_RELAY —
    a retryable error (explicitly listed in the S15 spec).  The message enters
    the retry loop.  A relay peer then joins the service node, and the next
    retry succeeds.
    Expected: send() returns Ok(RequestId), then eventually Propagated.
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
                send_result = edge_sender.send_message(message=msg)
                assert send_result.is_ok(), f"send() failed: {send_result.err()}"
                request_id = send_result.ok_value
                assert request_id, "send() returned an empty RequestId"

                delay(SERVICE_DOWN_SETTLE_S)

                early_propagated = wait_for_propagated(sender_collector, request_id, timeout_s=0)
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
                    propagated = wait_for_propagated(
                        collector=sender_collector,
                        request_id=request_id,
                        timeout_s=RECOVERY_TIMEOUT_S,
                    )
                    assert propagated is not None, (
                        f"No message_propagated within {RECOVERY_TIMEOUT_S}s "
                        f"after relay peer joined. "
                        f"Collected events: {sender_collector.events}"
                    )
                    assert propagated["requestId"] == request_id

                    error = wait_for_error(sender_collector, request_id, timeout_s=0)
                    assert error is None, f"Unexpected message_error after recovery: {error}"

                    assert_event_invariants(sender_collector, request_id)
