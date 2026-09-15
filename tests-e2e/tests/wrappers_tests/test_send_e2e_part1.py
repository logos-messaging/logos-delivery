from concurrent.futures import ThreadPoolExecutor

import pytest
from src.env_vars import NODE_2
from src.steps.common import StepsCommon
from src.libs.common import delay, to_base64
from src.libs.custom_logger import get_custom_logger
from src.node.waku_node import WakuNode
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
from src.steps.store import StepsStore
from tests.wrappers_tests.conftest import free_port

logger = get_custom_logger(__name__)

## max time to wait after sending the message
PROPAGATED_TIMEOUT_S = 30.0
SENT_TIMEOUT_S = 10.0
NO_SENT_OBSERVATION_S = 5.0
SENT_AFTER_STORE_TIMEOUT_S = 60.0
NO_STORE_OBSERVATION_S = 60.0
RECOVERY_TIMEOUT_S = 45.0

# S20 stabilization delays for gossipsub mesh formation.
MESH_STABILIZATION_S = 10
STORE_JOIN_STABILIZATION_S = 10

# MaxTimeInCache from send_service.nim.
MAX_TIME_IN_CACHE_S = 60.0
# Extra slack to cover the background retry loop tick after the window expires.
CACHE_EXPIRY_SLACK_S = 10.0
ERROR_AFTER_CACHE_EXPIRY_TIMEOUT_S = MAX_TIME_IN_CACHE_S + CACHE_EXPIRY_SLACK_S
RETRY_WINDOW_EXPIRED_MSG = "Unable to send within retry time window"

# S30: concurrent sends on the same content topic during initial auto-subscribe.
S30_CONCURRENT_SENDS = 5
S30_CONTENT_TOPIC = "/test/1/s30-concurrent/proto"

# S31: concurrent sends across mixed topics during peer churn.
S31_BURST_SIZE = 8
S31_CONTENT_TOPICS = [
    "/test/1/s31-topic-a/proto",
    "/test/1/s31-topic-b/proto",
    "/test/1/s31-topic-c/proto",
    "/test/1/s31-topic-d/proto",
    "/test/1/s31-topic-e/proto",
    "/test/1/s31-topic-f/proto",
    "/test/1/s31-topic-g/proto",
    "/test/1/s31-topic-h/proto",
]


class TestSendBeforeRelay(StepsStore):
    def test_s17_send_before_relay_peers_joins(self, node_config):
        """
        S17: sender starts isolated, calls send()
          - send() returns Ok(RequestId) immediately
          - Propagated event eventually arrives
        """
        sender_collector = EventCollector()

        node_config.update(
            {
                "relay": True,
                "store": False,
                "discv5Discovery": False,
                "numShardsInNetwork": 1,
            }
        )

        sender_result = WrapperManager.create_and_start(
            config=node_config,
            event_cb=sender_collector.event_callback,
        )
        assert sender_result.is_ok(), f"Failed to start sender: {sender_result.err()}"

        with sender_result.ok_value as sender_node:
            message = create_message_bindings()
            send_result = sender_node.send_message(message=message)
            assert send_result.is_ok(), f"send() must return Ok(RequestId) even with no peers, got: {send_result.err()}"

            request_id = send_result.ok_value
            assert request_id, "send() returned an empty RequestId"

            # Step 2: start a relay peer with store enabled.
            relay_config = {
                **node_config,
                "staticnodes": [get_node_multiaddr(sender_node)],
                "portsShift": 1,
                "store": True,
            }

            relay_result = WrapperManager.create_and_start(config=relay_config)
            assert relay_result.is_ok(), f"Failed to start relay peer: {relay_result.err()}"

            with relay_result.ok_value:
                # Match the gating part2's tests use: wait until the sender
                # actually reports Connected/PartiallyConnected before asserting
                # on propagation. Without this, the wait_for_propagated poll can
                # miss the event because the sender's mesh hasn't formed yet.
                assert wait_for_connected(sender_collector) is not None, (
                    f"Sender did not reach Connected/PartiallyConnected after " f"relay peer joined. Collected events: {sender_collector.events}"
                )

                propagated_event = wait_for_propagated(
                    collector=sender_collector,
                    request_id=request_id,
                    timeout_s=PROPAGATED_TIMEOUT_S,
                )
                assert propagated_event is not None, (
                    f"No MessagePropagatedEvent received within {PROPAGATED_TIMEOUT_S}s "
                    f"after relay peer joined. Collected events: {sender_collector.events}"
                )
                sent_event = wait_for_sent(
                    collector=sender_collector,
                    request_id=request_id,
                    timeout_s=SENT_TIMEOUT_S,
                )
                assert sent_event is not None, (
                    f"No MessageSentEvent received within {SENT_TIMEOUT_S}s "
                    f"from a store-enabled relay peer. Collected events: {sender_collector.events}"
                )

                assert_event_invariants(sender_collector, request_id)

    @pytest.mark.docker_required
    @pytest.mark.xfail(reason="fails to republish after store peer joins mesh see https://github.com/logos-messaging/logos-delivery/issues/3848")
    def test_s19_store_peer_appears_after_propagation(self, node_config):
        """
        S19: a store peer comes online later.
          - send() returns Ok(RequestId) immediately
          - Propagated --- relay peer
          - Sent when store peer is reachable
        """
        sender_collector = EventCollector()

        node_config.update({"relay": True, "store": False, "discv5Discovery": False, "numShardsInNetwork": 1, "reliabilityEnabled": True})

        sender_result = WrapperManager.create_and_start(
            config=node_config,
            event_cb=sender_collector.event_callback,
        )
        assert sender_result.is_ok(), f"Failed to start sender: {sender_result.err()}"

        with sender_result.ok_value as sender_node:
            # relay peer
            relay_config = {
                **node_config,
                "tcpPort": free_port(),
                "discv5UdpPort": free_port(),
                "restPort": free_port(),
                "staticnodes": [get_node_multiaddr(sender_node)],
                "store": False,
                "reliabilityEnabled": True,
            }

            relay_result = WrapperManager.create_and_start(config=relay_config)
            assert relay_result.is_ok(), f"Failed to start relay peer: {relay_result.err()}"

            with relay_result.ok_value as relay_peer:
                # Wait until the sender actually reports a connection before
                # sending. Without this, send() can race the static-peer
                # dial on slower runners (same gate S17 uses).
                assert wait_for_connected(sender_collector) is not None, (
                    f"Sender did not reach Connected/PartiallyConnected after " f"relay peer joined. Collected events: {sender_collector.events}"
                )
                message = create_message_bindings()
                send_result = sender_node.send_message(message=message)
                assert send_result.is_ok(), f"send() must return Ok(RequestId), got: {send_result.err()}"

                request_id = send_result.ok_value
                assert request_id, "send() returned an empty RequestId"

                # Propagated should arrive via the relay peer.
                propagated_event = wait_for_propagated(
                    collector=sender_collector,
                    request_id=request_id,
                    timeout_s=PROPAGATED_TIMEOUT_S,
                )
                assert propagated_event is not None, (
                    f"No MessagePropagatedEvent received within {PROPAGATED_TIMEOUT_S}s. " f"Collected events: {sender_collector.events}"
                )

                early_sent_event = wait_for_sent(
                    collector=sender_collector,
                    request_id=request_id,
                    timeout_s=NO_SENT_OBSERVATION_S,
                )
                assert early_sent_event is None, f"MessageSentEvent arrived before any store peer was reachable. " f"Event: {early_sent_event}"

                # Store peer
                store_node = WakuNode(NODE_2, f"store_node")
                store_node.start(relay="true", store="true", discv5_discovery="false", cluster_id=node_config["clusterId"], shard=0)
                store_node.set_relay_subscriptions([self.test_pubsub_topic])
                relay_multiaddr = get_node_multiaddr(relay_peer)
                sender_multiaddr = get_node_multiaddr(sender_node)
                store_node.add_peers([relay_multiaddr, sender_multiaddr])
                self.wait_for_autoconnection([store_node], hard_wait=40)
                delay(3)

                sent_event = wait_for_sent(
                    collector=sender_collector,
                    request_id=request_id,
                    timeout_s=SENT_AFTER_STORE_TIMEOUT_S,
                )

                assert sent_event is not None, (
                    f"No MessageSentEvent received within {SENT_AFTER_STORE_TIMEOUT_S}s "
                    f"after store peer joined. Collected events: {sender_collector.events}"
                )

                self.check_published_message_is_stored(
                    store_node=store_node,
                    pubsub_topic=self.test_pubsub_topic,
                    messages_to_check=[message],
                    page_size=5,
                    ascending="true",
                )

                assert_event_invariants(sender_collector, request_id)

    @pytest.mark.docker_required
    @pytest.mark.skip(reason="Forcing the miss store round not possible")
    def test_s20_store_misses_initially_then_retry_succeeds(self, node_config):
        """
        S20: relay propagation succeeds, the first store query misses
        (the store peer is reachable but does not yet have the message),
        a later retry republishes through the relay mesh, and the store
        peer then archives it.

        Covers state flow:
            SuccessfullyPropagated -> NextRoundRetry
              -> SuccessfullyPropagated -> SuccessfullyValidated

        """
        sender_collector = EventCollector()
        store_node = WakuNode(NODE_2, f"s20_store_node_{self.test_id}")
        store_node.start(
            relay="true",
            store="true",
            discv5_discovery="false",
            cluster_id=node_config["clusterId"],
            shard=0,
        )
        store_multiaddr = store_node.get_multiaddr_with_id()

        node_config.update(
            {
                "relay": True,
                "store": False,
                "discv5Discovery": False,
                "numShardsInNetwork": 1,
                "reliabilityEnabled": True,
                "storenode": store_multiaddr,
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
                "store": False,
            }
            relay_result = WrapperManager.create_and_start(config=relay_config)
            assert relay_result.is_ok(), f"Failed to start relay peer: {relay_result.err()}"

            with relay_result.ok_value as relay_peer:
                # Wait for the sender to see the relay peer before publishing.
                assert wait_for_connected(sender_collector) is not None, (
                    f"Sender did not reach Connected/PartiallyConnected. " f"Collected events: {sender_collector.events}"
                )

                # Let the gossipsub mesh form between sender and relay peer.
                delay(MESH_STABILIZATION_S)

                message = create_message_bindings(ephemeral=False)
                send_result = sender_node.send_message(message=message)
                assert send_result.is_ok(), f"send() must return Ok(RequestId), got: {send_result.err()}"

                request_id = send_result.ok_value
                assert request_id, "send() returned an empty RequestId"

                # Round 1: propagation succeeds via the relay peer.
                propagated_event = wait_for_propagated(
                    collector=sender_collector,
                    request_id=request_id,
                    timeout_s=PROPAGATED_TIMEOUT_S,
                )
                assert propagated_event is not None, (
                    f"No MessagePropagatedEvent within {PROPAGATED_TIMEOUT_S}s. " f"Collected events: {sender_collector.events}"
                )

                # The store peer is reachable for queries but never received
                # the message via gossipsub, so the first store query must
                # miss and Sent must NOT arrive yet.
                early_sent_event = wait_for_sent(
                    collector=sender_collector,
                    request_id=request_id,
                    timeout_s=NO_SENT_OBSERVATION_S,
                )
                assert early_sent_event is None, (
                    f"MessageSentEvent arrived before the store could have the message. "
                    f"Initial store query should have missed. Event: {early_sent_event}"
                )

                # Now subscribe the store to the test topic and wire it into
                # the relay mesh so the next retry round's republish reaches
                # the store via gossipsub.
                store_node.set_relay_subscriptions([self.test_pubsub_topic])
                store_node.add_peers([get_node_multiaddr(sender_node), get_node_multiaddr(relay_peer)])
                self.wait_for_autoconnection([store_node], hard_wait=10)
                delay(STORE_JOIN_STABILIZATION_S)

                # Round 2: retry republishes, store archives, next query hits.
                sent_event = wait_for_sent(
                    collector=sender_collector,
                    request_id=request_id,
                    timeout_s=SENT_AFTER_STORE_TIMEOUT_S,
                )
                assert sent_event is not None, (
                    f"No MessageSentEvent within {SENT_AFTER_STORE_TIMEOUT_S}s "
                    f"after the store joined the relay mesh. The retry round "
                    f"should have republished and the store should have archived. "
                    f"Collected events: {sender_collector.events}"
                )

                self.check_published_message_is_stored(
                    store_node=store_node,
                    pubsub_topic=self.test_pubsub_topic,
                    messages_to_check=[message],
                    page_size=5,
                    ascending="true",
                )

                assert_event_invariants(sender_collector, request_id)

    def test_s21_error_when_retry_window_expires(self, node_config):
        """
        S21: delivery retry window expires before any valid path recovers.
        """
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

        with sender_result.ok_value as sender_node:
            message = create_message_bindings()
            send_result = sender_node.send_message(message=message)
            assert send_result.is_ok(), f"send() must return Ok(RequestId) even with no peers, got: {send_result.err()}"

            request_id = send_result.ok_value
            assert request_id, "send() returned an empty RequestId"

            # No peer
            error_event = wait_for_error(
                collector=sender_collector,
                request_id=request_id,
                timeout_s=ERROR_AFTER_CACHE_EXPIRY_TIMEOUT_S,
            )
            assert error_event is not None, (
                f"No MessageErrorEvent received within {ERROR_AFTER_CACHE_EXPIRY_TIMEOUT_S}s "
                f"(MaxTimeInCache={MAX_TIME_IN_CACHE_S}s + slack). "
                f"Collected events: {sender_collector.events}"
            )
            logger.info(f"S21 received error event: {error_event}")

            assert error_event.get("error") == RETRY_WINDOW_EXPIRED_MSG, (
                f"Unexpected error message in message_error event.\n"
                f"Expected: {RETRY_WINDOW_EXPIRED_MSG!r}\n"
                f"Got:      {error_event.get('error')!r}\n"
                f"Full event: {error_event}"
            )

            assert_event_invariants(sender_collector, request_id)

    def test_s22_non_ephemeral_message_with_reliability_disabled(self, node_config):
        """
        S22: non-ephemeral message with reliabilityEnabled disabled.
          - propagation path exists ,reliabilityEnabled = false.
          - Expected: Ok(RequestId), Propagated event only, no Sent event.
          Note: S17 already covers the positive path of this test with reliabilityEnabled=True.
        """
        sender_collector = EventCollector()

        node_config.update(
            {
                "relay": True,
                "store": False,
                "discv5Discovery": False,
                "numShardsInNetwork": 1,
                "reliabilityEnabled": False,
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
                "store": True,
            }

            relay_result = WrapperManager.create_and_start(config=relay_config)
            assert relay_result.is_ok(), f"Failed to start relay peer: {relay_result.err()}"

            with relay_result.ok_value:
                # Wait for the sender to actually establish the mesh before
                # publishing, matching part2's pattern. Otherwise the publish
                # races with mesh formation and message_propagated may not fire.
                assert wait_for_connected(sender_collector) is not None, (
                    f"Sender did not reach Connected/PartiallyConnected. " f"Collected events: {sender_collector.events}"
                )

                message = create_message_bindings(ephemeral=False)
                send_result = sender_node.send_message(message=message)
                assert send_result.is_ok(), f"send() must return Ok(RequestId), got: {send_result.err()}"

                request_id = send_result.ok_value
                assert request_id, "send() returned an empty RequestId"

                propagated_event = wait_for_propagated(
                    collector=sender_collector,
                    request_id=request_id,
                    timeout_s=PROPAGATED_TIMEOUT_S,
                )
                assert propagated_event is not None, (
                    f"No MessagePropagatedEvent received within {PROPAGATED_TIMEOUT_S}s. " f"Collected events: {sender_collector.events}"
                )

                sent_event = wait_for_sent(
                    collector=sender_collector,
                    request_id=request_id,
                    timeout_s=NO_SENT_OBSERVATION_S,
                )
                assert sent_event is None, (
                    f"Unexpected MessageSentEvent received when reliabilityEnabled is disabled.\n"
                    f"Sent event: {sent_event}\n"
                    f"Collected events: {sender_collector.events}"
                )

                assert_event_invariants(sender_collector, request_id)

    def test_s23_no_sent_event_when_relay_has_no_store(self, node_config):
        """
        S23: non-ephemeral message, reliability enabled, no store peer ever reachable.
          - Expected: Ok(RequestId), Propagated event only, no Sent and no terminal error.
        """
        sender_collector = EventCollector()

        node_config.update(
            {
                "relay": True,
                "store": False,
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

        with sender_result.ok_value as sender_node:
            message = create_message_bindings(ephemeral=False)
            send_result = sender_node.send_message(message=message)
            assert send_result.is_ok(), f"send() must return Ok(RequestId) even with no peers, got: {send_result.err()}"

            request_id = send_result.ok_value
            assert request_id, "send() returned an empty RequestId"

            relay_config = {
                **node_config,
                "staticnodes": [get_node_multiaddr(sender_node)],
                "portsShift": 1,
                "store": False,
            }

            relay_result = WrapperManager.create_and_start(config=relay_config)
            assert relay_result.is_ok(), f"Failed to start relay peer: {relay_result.err()}"

            with relay_result.ok_value:
                propagated_event = wait_for_propagated(
                    collector=sender_collector,
                    request_id=request_id,
                    timeout_s=PROPAGATED_TIMEOUT_S,
                )
                assert propagated_event is not None, (
                    f"No MessagePropagatedEvent received within {PROPAGATED_TIMEOUT_S}s "
                    f"after relay peer joined. Collected events: {sender_collector.events}"
                )

                sent_event = wait_for_sent(
                    collector=sender_collector,
                    request_id=request_id,
                    timeout_s=NO_STORE_OBSERVATION_S,
                )
                assert sent_event is None, (
                    f"Unexpected MessageSentEvent within {NO_STORE_OBSERVATION_S}s "
                    f"when relay peer has store=false.\n"
                    f"Sent event: {sent_event}\n"
                    f"Collected events: {sender_collector.events}"
                )

                # Regression guard: current behavior must NOT convert "no store
                # reachable" into an immediate terminal error. If a future change
                # starts emitting one, this assertion will catch it.
                error_event = wait_for_error(
                    collector=sender_collector,
                    request_id=request_id,
                    timeout_s=0,
                )
                assert error_event is None, (
                    f"Unexpected terminal error event when no store peer is reachable. "
                    f"S23 expects silent behavior (Propagated only).\n"
                    f"Error event: {error_event}\n"
                    f"Collected events: {sender_collector.events}"
                )

                assert_event_invariants(sender_collector, request_id)

    def test_s24_ephemeral_message_with_reachable_store(self, node_config):
        """
        S24: ephemeral message, reliability enabled, reachable store peer.
          - Setup: propagation path exists, relay peer has store=True (reachable),
          - Expected: Ok(RequestId), Propagated event only, no Sent event.
        """

        sender_collector = EventCollector()

        node_config.update(
            {
                "relay": True,
                "store": False,
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

        with sender_result.ok_value as sender_node:
            relay_config = {
                **node_config,
                "staticnodes": [get_node_multiaddr(sender_node)],
                "portsShift": 1,
                "store": True,
            }

            relay_result = WrapperManager.create_and_start(config=relay_config)
            assert relay_result.is_ok(), f"Failed to start relay peer: {relay_result.err()}"

            with relay_result.ok_value:
                message = create_message_bindings(ephemeral=True)
                send_result = sender_node.send_message(message=message)
                assert send_result.is_ok(), f"send() must return Ok(RequestId), got: {send_result.err()}"

                request_id = send_result.ok_value
                assert request_id, "send() returned an empty RequestId"

                propagated_event = wait_for_propagated(
                    collector=sender_collector,
                    request_id=request_id,
                    timeout_s=PROPAGATED_TIMEOUT_S,
                )
                assert propagated_event is not None, (
                    f"No MessagePropagatedEvent received within {PROPAGATED_TIMEOUT_S}s. " f"Collected events: {sender_collector.events}"
                )

                sent_event = wait_for_sent(
                    collector=sender_collector,
                    request_id=request_id,
                    timeout_s=NO_STORE_OBSERVATION_S,
                )
                assert sent_event is None, (
                    f"Unexpected MessageSentEvent for an ephemeral message. "
                    f"Ephemeral messages must never be store-validated.\n"
                    f"Sent event: {sent_event}\n"
                    f"Collected events: {sender_collector.events}"
                )

                assert_event_invariants(sender_collector, request_id)

    def test_s26_lightpush_peer_churn_alternate_remains(self, node_config):
        """
        S26: multiple lightpush peers, the selected one disappears,
             an alternate remains.

        Topology (3 peers + sender):
          - peer1: relay + lightpush. The lightpush server initially selected
            by the sender. Stopped mid-test to simulate churn.
          - relay_peer: relay-only. Kept alive throughout the test as a
            stable gossipsub mesh neighbour, so that after peer1 disappears
            peer2 still has a relay path to propagate the message.
          - peer2: relay + lightpush. The surviving lightpush server that
            must take over once peer1 is gone.
          - sender: edge node with peer1 and peer2 as static lightpush peers.
        """
        sender_collector = EventCollector()
        peer1_config = {
            **node_config,
            "relay": True,
            "lightpush": True,
            "store": False,
            "filter": False,
            "discv5Discovery": True,
            "numShardsInNetwork": 1,
            "portsShift": 1,
            "discv5UdpPort": free_port(),
        }
        peer1_result = WrapperManager.create_and_start(config=peer1_config)
        assert peer1_result.is_ok(), f"Failed to start lightpush peer1: {peer1_result.err()}"
        peer1 = peer1_result.ok_value

        relay_config = {
            **node_config,
            "relay": True,
            "lightpush": False,
            "store": False,
            "filter": False,
            "discv5Discovery": False,
            "numShardsInNetwork": 1,
            "portsShift": 4,
        }

        relay_result = WrapperManager.create_and_start(config=relay_config)
        assert relay_result.is_ok(), f"Failed to start relay peer: {relay_result.err()}"

        with relay_result.ok_value as relay_peer:
            peer2_config = {
                **peer1_config,
                "staticnodes": [
                    get_node_multiaddr(peer1),
                    get_node_multiaddr(relay_peer),
                ],
                "portsShift": 2,
                "discv5UdpPort": free_port(),
            }

            peer2_result = WrapperManager.create_and_start(config=peer2_config)
            assert peer2_result.is_ok(), f"Failed to start lightpush peer2: {peer2_result.err()}"

            with peer2_result.ok_value as peer2:
                sender_config = {
                    **node_config,
                    "mode": "Edge",
                    "relay": False,
                    "store": False,
                    "filter": False,
                    "discv5Discovery": False,
                    "numShardsInNetwork": 1,
                    "portsShift": 3,
                    "staticnodes": [
                        get_node_multiaddr(peer1),
                        get_node_multiaddr(peer2),
                    ],
                }

                sender_result = WrapperManager.create_and_start(
                    config=sender_config,
                    event_cb=sender_collector.event_callback,
                )
                assert sender_result.is_ok(), f"Failed to start sender: {sender_result.err()}"

                with sender_result.ok_value as sender_node:
                    delay(2)
                    stop_result = peer1.stop_and_destroy()
                    assert stop_result.is_ok(), f"Failed to stop peer1: {stop_result.err()}"
                    delay(2)

                    message = create_message_bindings()
                    send_result = sender_node.send_message(message=message)
                    assert send_result.is_ok(), f"send() must return Ok(RequestId) during peer churn, got: {send_result.err()}"

                    request_id = send_result.ok_value
                    assert request_id, "send() returned an empty RequestId"

                    # Expect Propagated via the surviving lightpush peer (peer2).
                    propagated_event = wait_for_propagated(
                        collector=sender_collector,
                        request_id=request_id,
                        timeout_s=PROPAGATED_TIMEOUT_S,
                    )
                    assert propagated_event is not None, (
                        f"No MessagePropagatedEvent within {PROPAGATED_TIMEOUT_S}s "
                        f"after the selected lightpush peer disappeared. "
                        f"Collected events: {sender_collector.events}"
                    )

                    error_event = wait_for_error(
                        collector=sender_collector,
                        request_id=request_id,
                        timeout_s=0,
                    )
                    assert error_event is None, f"Unexpected message_error event during peer churn: {error_event}"

                    assert_event_invariants(sender_collector, request_id)

    def test_s30_concurrent_sends_during_auto_subscribe(self, node_config):
        """
        S30: concurrent sends on the same content topic during initial auto-subscribe.
          - Sender starts unsubscribed to the target topic.
          - Several send() calls are issued at nearly the same time.
          - Each call must return Ok(RequestId) with a unique id.
          - Each request id must get its own propagated event,
            with no dropped or cross-associated events.
        """
        sender_collector = EventCollector()

        node_config.update(
            {
                "relay": True,
                "store": False,
                "discv5Discovery": False,
                "numShardsInNetwork": 1,
            }
        )

        sender_result = WrapperManager.create_and_start(
            config=node_config,
            event_cb=sender_collector.event_callback,
        )
        assert sender_result.is_ok(), f"Failed to start sender: {sender_result.err()}"

        with sender_result.ok_value as sender_node:
            # Relay peer so the sender has a propagation path.
            relay_config = {
                **node_config,
                "staticnodes": [get_node_multiaddr(sender_node)],
                "portsShift": 1,
            }

            relay_result = WrapperManager.create_and_start(config=relay_config)
            assert relay_result.is_ok(), f"Failed to start relay peer: {relay_result.err()}"

            with relay_result.ok_value:
                # Build one message per send, with distinct payloads so we can
                # detect any cross-association between request ids and events.
                messages = [
                    create_message_bindings(
                        contentTopic=S30_CONTENT_TOPIC,
                        payload=to_base64(f"s30-concurrent-{i}"),
                    )
                    for i in range(S30_CONCURRENT_SENDS)
                ]

                # Fire all sends concurrently. The sender is not yet subscribed
                # to S30_CONTENT_TOPIC, so this exercises the auto-subscribe path
                # under contention.
                with ThreadPoolExecutor(max_workers=S30_CONCURRENT_SENDS) as pool:
                    send_results = list(pool.map(sender_node.send_message, messages))

                # Every send must return Ok(RequestId).
                request_ids = []
                for i, send_result in enumerate(send_results):
                    assert send_result.is_ok(), f"Concurrent send #{i} failed: {send_result.err()}"
                    request_id = send_result.ok_value
                    assert request_id, f"Concurrent send #{i} returned an empty RequestId"
                    request_ids.append(request_id)

                # Request ids must be unique across concurrent sends.
                assert len(set(request_ids)) == len(request_ids), f"Duplicate RequestIds returned by concurrent sends: {request_ids}"

                # Each request id must get its own propagated event and no error.
                for request_id in request_ids:
                    propagated_event = wait_for_propagated(
                        collector=sender_collector,
                        request_id=request_id,
                        timeout_s=PROPAGATED_TIMEOUT_S,
                    )
                    assert propagated_event is not None, (
                        f"No MessagePropagatedEvent for request_id={request_id} "
                        f"within {PROPAGATED_TIMEOUT_S}s. "
                        f"Collected events: {sender_collector.events}"
                    )

                    error_event = wait_for_error(
                        collector=sender_collector,
                        request_id=request_id,
                        timeout_s=0,
                    )
                    assert error_event is None, f"Unexpected message_error for request_id={request_id}: {error_event}"

                # Cross-association guard: every event with a requestId must
                # belong to exactly one of the request ids we issued.
                issued = set(request_ids)
                for event in sender_collector.snapshot():
                    event_request_id = event.get("requestId")
                    if event_request_id is None:
                        continue
                    assert event_request_id in issued, (
                        f"Event carries an unknown requestId={event_request_id!r}, " f"not in issued set {issued}. Event: {event}"
                    )

                # Per-request invariants apply to every concurrent send
                # (correct requestId, no duplicate terminal events,
                # Sent never before Propagated).
                for request_id in request_ids:
                    assert_event_invariants(sender_collector, request_id)

    @pytest.mark.docker_required
    def test_s31_concurrent_sends_mixed_topics_during_churn(self, node_config):
        """
        S31: concurrent sends across mixed content topics during peer churn.
        """
        sender_collector = EventCollector()

        relay_peer = WakuNode(NODE_2, f"s31_relay_peer_{self.test_id}")
        relay_peer.start(relay="true", discv5_discovery="false")
        relay_peer.set_relay_subscriptions([self.test_pubsub_topic])

        lightpush_peer = WakuNode(NODE_2, f"s31_lightpush_peer_{self.test_id}")
        lightpush_peer.start(relay="true", lightpush="true", discv5_discovery="false")
        lightpush_peer.set_relay_subscriptions([self.test_pubsub_topic])

        store_peer = WakuNode(NODE_2, f"s31_store_peer_{self.test_id}")
        store_peer.start(relay="true", store="true", discv5_discovery="false")
        store_peer.set_relay_subscriptions([self.test_pubsub_topic])

        churn_peers = [relay_peer, lightpush_peer, store_peer]

        # Mesh docker peers so a lightpushed message can fan out to the store peer.
        peer_multiaddrs = [p.get_multiaddr_with_id() for p in churn_peers]
        for peer in churn_peers:
            others = [a for a in peer_multiaddrs if a != peer.get_multiaddr_with_id()]
            peer.add_peers(others)

        node_config.update(
            {
                "mode": "Edge",
                "relay": False,
                "store": False,
                "discv5Discovery": False,
                "numShardsInNetwork": 1,
                "lightpushnode": lightpush_peer.get_multiaddr_with_id(),
            }
        )

        sender_result = WrapperManager.create_and_start(
            config=node_config,
            event_cb=sender_collector.event_callback,
        )
        assert sender_result.is_ok(), f"Failed to start sender: {sender_result.err()}"

        with sender_result.ok_value as sender_node:
            sender_multiaddr = get_node_multiaddr(sender_node)
            for peer in churn_peers:
                peer.add_peers([sender_multiaddr])
            delay(3)  # let docker peers connect to the sender

            all_request_ids: list[str] = []
            phase1_ids = self._s31_fire_burst(sender_node, phase_label="phase1")
            all_request_ids.extend(phase1_ids)

            for peer in churn_peers:
                peer.restart(wait_for_node_sec=None)
            delay(1)  # small window so the restart is actually in-flight
            phase2_ids = self._s31_fire_burst(sender_node, phase_label="phase2")
            all_request_ids.extend(phase2_ids)

            # Wait for all peers to be ready again and re-attach the sender.
            for peer in churn_peers:
                peer.ensure_ready(timeout_duration=20)
                peer.add_peers([sender_multiaddr])

            peer_multiaddrs = [p.get_multiaddr_with_id() for p in churn_peers]
            for peer in churn_peers:
                others = [a for a in peer_multiaddrs if a != peer.get_multiaddr_with_id()]
                peer.add_peers(others)
            delay(3)

            phase3_ids = self._s31_fire_burst(sender_node, phase_label="phase3")
            all_request_ids.extend(phase3_ids)

            assert len(set(all_request_ids)) == len(all_request_ids), f"Duplicate RequestIds across bursts: {all_request_ids}"

            # Phase 1 ran before any churn, so the mesh was stable — standard timeout.
            # Phase 3 ran right after restart + re-attach, so the mesh needed to
            # re-stabilize — use the recovery timeout to avoid CI flakiness.
            phase_timeouts = [
                (phase1_ids, PROPAGATED_TIMEOUT_S),
                (phase3_ids, RECOVERY_TIMEOUT_S),
            ]
            for request_ids, timeout_s in phase_timeouts:
                for request_id in request_ids:
                    propagated_event = wait_for_propagated(
                        collector=sender_collector,
                        request_id=request_id,
                        timeout_s=timeout_s,
                    )
                    assert propagated_event is not None, (
                        f"No MessagePropagatedEvent for stable-phase "
                        f"request_id={request_id} within {timeout_s}s. "
                        f"Collected events: {sender_collector.events}"
                    )

                    error_event = wait_for_error(
                        collector=sender_collector,
                        request_id=request_id,
                        timeout_s=0,
                    )
                    assert error_event is None, f"Unexpected message_error event for stable-phase " f"request_id={request_id}: {error_event}"

            for request_id in phase2_ids:
                error_event = wait_for_error(
                    collector=sender_collector,
                    request_id=request_id,
                    timeout_s=0,
                )
                assert error_event is None, f"Unexpected terminal message_error for phase-2 " f"request_id={request_id} after recovery: {error_event}"

            issued = set(all_request_ids)
            for event in sender_collector.snapshot():
                event_request_id = event.get("requestId")
                if event_request_id is None:
                    continue
                assert event_request_id in issued, (
                    f"Event carries an unknown requestId={event_request_id!r}, " f"not in issued set {issued}. Event: {event}"
                )

            # Use the hash the wrapper emitted on message_sent so the store
            # lookup matches the exact bytes that were actually published.
            phase3_hashes = []
            for request_id in phase3_ids:
                sent_event = wait_for_sent(
                    collector=sender_collector,
                    request_id=request_id,
                    timeout_s=RECOVERY_TIMEOUT_S,
                )
                assert sent_event is not None, (
                    f"No message_sent event for phase-3 request_id={request_id} "
                    f"within {RECOVERY_TIMEOUT_S}s. Collected events: {sender_collector.events}"
                )
                msg_hash = sent_event.get("messageHash")
                assert msg_hash, f"message_sent event missing messageHash: {sent_event}"
                phase3_hashes.append(msg_hash)

            # 3 phases × S31_BURST_SIZE messages, so the page must fit them all,
            # otherwise phase-3 hashes (which sort last in ascending order) get cut off.
            self.check_sent_message_is_stored(
                expected_hashes=phase3_hashes,
                store_node=store_peer,
                pubsub_topic=self.test_pubsub_topic,
                page_size=S31_BURST_SIZE * 3,
                ascending="true",
            )

            # Per-request invariants apply across all phases, including the
            # retry-path bursts (phase 2). If retries ever emit duplicate
            # Propagated events or reorder Sent before Propagated, this catches it.
            for request_id in all_request_ids:
                assert_event_invariants(sender_collector, request_id)

    def _s31_fire_burst(self, sender_node, *, phase_label: str) -> list[str]:
        """Fire S31_BURST_SIZE concurrent sends, one per topic in S31_CONTENT_TOPICS.
        Returns the list of RequestIds. Asserts every send returned Ok."""
        messages = [
            self.create_message(
                contentTopic=S31_CONTENT_TOPICS[i],
                payload=to_base64(f"s31-{phase_label}-{i}"),
            )
            for i in range(S31_BURST_SIZE)
        ]

        with ThreadPoolExecutor(max_workers=S31_BURST_SIZE) as pool:
            send_results = list(pool.map(sender_node.send_message, messages))

        request_ids = []
        for i, send_result in enumerate(send_results):
            assert send_result.is_ok(), f"{phase_label}: concurrent send #{i} failed: {send_result.err()}"
            request_id = send_result.ok_value
            assert request_id, f"{phase_label}: concurrent send #{i} returned an empty RequestId"
            request_ids.append(request_id)

        return request_ids
