import pytest
from src.env_vars import NODE_1
from src.steps.common import StepsCommon
from src.libs.common import delay, to_base64
from src.node.waku_node import WakuNode
from src.node.wrappers_manager import WrapperManager
from src.node.wrapper_helpers import (
    EventCollector,
    assert_event_invariants,
    create_message_bindings,
    get_node_multiaddr,
    wait_for_propagated,
    wait_for_sent,
    wait_for_error,
)
from src.test_data import DEFAULT_CLUSTER_ID
from tests.wrappers_tests.conftest import build_node_config


PROPAGATED_TIMEOUT_S = 30.0
NO_SENT_OBSERVATION_S = 5.0
SENT_AFTER_STORE_TIMEOUT_S = 60.0
RECOVERY_TIMEOUT_S = 45.0
SERVICE_DOWN_SETTLE_S = 3.0

# Default-cluster shard-0 pubsub topic; used to subscribe the S11 docker store
# peer so it joins the same relay mesh as the wrapper nodes (wrapper config
# uses numShardsInNetwork=1 => shard 0).
STORE_PEER_PUBSUB_TOPIC = f"/waku/2/rs/{DEFAULT_CLUSTER_ID}/0"


class TestS11EdgeSenderLightpushAndStore(StepsCommon):
    """
    S11 — Edge sender with lightpush path and store validation.
    Edge sender has no local relay; it publishes via a wrapper lightpush peer
    and validates delivery via a docker store peer. Reliability enabled.
    Topology:
        [LightpushPeer] wrapper, relay=True, lightpush=True, store=False
        [StorePeer]     docker WakuNode, relay=true, store=true,
                        dials the lightpush peer via add_peers and subscribes
                        to the same shard-0 pubsub topic so it joins the
                        relay mesh and archives propagated messages.
        [Edge]          wrapper, mode="Edge",
                        staticnodes=[lightpush_peer],
                        storenode=store_peer,
                        reliabilityEnabled=True
    Expected: send() returns Ok(RequestId), Propagated arrives, then Sent
    (store validation succeeds), no Error.
    Purpose: edge-mode fully validated success path against a real docker
    store node (cross-implementation check).
    """

    @pytest.mark.docker_required
    def test_s11_edge_lightpush_with_store_validation(self):
        sender_collector = EventCollector()

        common = {
            "filter": False,
            "discv5Discovery": True,
            "numShardsInNetwork": 1,
        }

        lightpush_config = build_node_config(
            relay=True,
            lightpush=True,
            store=False,
            **common,
        )

        lightpush_result = WrapperManager.create_and_start(config=lightpush_config)
        assert lightpush_result.is_ok(), f"Failed to start lightpush peer: {lightpush_result.err()}"

        with lightpush_result.ok_value as lightpush_peer:
            lightpush_multiaddr = get_node_multiaddr(lightpush_peer)

            # Docker store peer — real nwaku node running as the store backend.
            # Dial the lightpush peer via add_peers and subscribe to the same
            # shard-0 pubsub topic so it joins the relay mesh and archives
            # messages propagated by the lightpush peer.
            store_peer = WakuNode(NODE_1, f"s11_store_{self.test_id}")
            store_peer.start(relay="true", store="true")
            self.add_node_peer(store_peer, [lightpush_multiaddr])
            store_peer.set_relay_subscriptions([STORE_PEER_PUBSUB_TOPIC])
            store_multiaddr = store_peer.get_multiaddr_with_id()

            edge_config = build_node_config(
                mode="Edge",
                relay=False,
                store=False,
                # assuming disc5v already happened
                staticnodes=[lightpush_multiaddr, store_multiaddr],
                reliabilityEnabled=True,
                **common,
            )

            edge_result = WrapperManager.create_and_start(
                config=edge_config,
                event_cb=sender_collector.event_callback,
            )
            assert edge_result.is_ok(), f"Failed to start edge sender: {edge_result.err()}"

            with edge_result.ok_value as edge_sender:
                message = create_message_bindings(
                    payload=to_base64("S11 edge lightpush + store test payload"),
                    contentTopic="/test/1/s11-edge-lightpush-store/proto",
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

                sent = wait_for_sent(
                    collector=sender_collector,
                    request_id=request_id,
                    timeout_s=SENT_AFTER_STORE_TIMEOUT_S,
                )
                assert sent is not None, (
                    f"No message_sent event within {SENT_AFTER_STORE_TIMEOUT_S}s " f"after propagation. Collected events: {sender_collector.events}"
                )
                assert sent["requestId"] == request_id

                error = wait_for_error(sender_collector, request_id, timeout_s=0)
                assert error is None, f"Unexpected message_error event: {error}"

                assert_event_invariants(sender_collector, request_id)


class TestS16LightpushPeerAppearsLater(StepsCommon):
    """
    S16 — No delivery peers at T0, lightpush peer appears later.
    The edge sender has the lightpush service in its staticnodes, but the
    service is stopped before the sender starts, so there is no reachable
    delivery peer at T0. send() is called while the service is down. The
    service is restarted during the retry window; the sender connects to it
    and a later retry delivers the message.
    Expected: send() returns Ok(RequestId), then eventually Propagated.
    """

    @pytest.mark.xfail(reason="binding cannot restart a node or add peers at runtime")
    def test_s16_lightpush_peer_appears_later(self):
        sender_collector = EventCollector()

        common = {
            "store": False,
            "filter": False,
            "discv5Discovery": False,
            "numShardsInNetwork": 1,
        }

        # Start the lightpush service once to obtain its multiaddr, then stop
        # it so the sender has no reachable peer at T0. The same node object
        # is restarted later, so the address stays valid.
        service_config = build_node_config(relay=True, lightpush=True, **common)
        service_result = WrapperManager.create_and_start(config=service_config)
        assert service_result.is_ok(), f"Failed to start lightpush peer: {service_result.err()}"

        with service_result.ok_value as service:
            service_multiaddr = get_node_multiaddr(service)

            stop_result = service.stop_node()
            assert stop_result.is_ok(), f"Failed to stop lightpush peer: {stop_result.err()}"
            delay(SERVICE_DOWN_SETTLE_S)

            # Edge sender is a lightpush client; its only peer is the service,
            # which is currently down.
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
                # send() is invoked while the service is down.
                msg = create_message_bindings(
                    payload=to_base64("S16 lightpush peer appears later"),
                    contentTopic="/test/1/s16-late-lightpush/proto",
                )
                send_result = edge_sender.send_message(message=msg)
                assert send_result.is_ok(), f"send() failed: {send_result.err()}"
                request_id = send_result.ok_value
                assert request_id, "send() returned an empty RequestId"

                delay(SERVICE_DOWN_SETTLE_S)

                early_propagated = wait_for_propagated(sender_collector, request_id, timeout_s=0)
                assert early_propagated is None, f"message_propagated arrived before the lightpush peer was reachable: {early_propagated}"

                # The lightpush peer comes back during the retry window.
                restart_result = service.start_node()
                assert restart_result.is_ok(), f"Failed to restart lightpush peer: {restart_result.err()}"

                propagated = wait_for_propagated(
                    collector=sender_collector,
                    request_id=request_id,
                    timeout_s=RECOVERY_TIMEOUT_S,
                )
                assert propagated is not None, (
                    f"No message_propagated within {RECOVERY_TIMEOUT_S}s "
                    f"after the lightpush peer joined. "
                    f"Collected events: {sender_collector.events}"
                )
                assert propagated["requestId"] == request_id

                error = wait_for_error(sender_collector, request_id, timeout_s=0)
                assert error is None, f"Unexpected message_error after recovery: {error}"

                assert_event_invariants(sender_collector, request_id)


class TestS18StagedTopologyReformation(StepsCommon):
    """
    S18: relay absent at T0, lightpush absent at T0, both appear in stages.

    The sender has relay and lightpush enabled but starts fully isolated:
    no relay peers and no lightpush peers. send() is called before any
    peer exists. Peers then appear one stage at a time. The message must
    succeed as soon as any valid path becomes available.

    Two orderings are covered, one per test method:
      - lightpush appears first, then relay.
      - relay appears first, then lightpush.

    Both prove the send service recovers from arbitrary staged topology
    reformation.

    Common topology per stage:
      [Sender]        relay=True, lightpush=True, isolated at T0.
      [LightpushPeer] relay=True, lightpush=True, staticnodes=[sender].
      [RelayPeer]     relay=True, staticnodes=[sender].
    """

    # Common config shared by the sender and both staged peers.
    _COMMON = {
        "relay": True,
        "lightpush": True,
        "store": False,
        "filter": False,
        "discv5Discovery": False,
        "numShardsInNetwork": 1,
    }

    def test_s18_lightpush_first_then_relay(self, node_config):
        """Sender isolated at T0; lightpush peer appears, then relay peer."""
        sender_collector = EventCollector()

        node_config.update(self._COMMON)

        sender_result = WrapperManager.create_and_start(
            config=node_config,
            event_cb=sender_collector.event_callback,
        )
        assert sender_result.is_ok(), f"Failed to start sender: {sender_result.err()}"

        with sender_result.ok_value as sender:
            # send() before any peer exists must still return Ok(RequestId).
            message = create_message_bindings(
                payload=to_base64("S18 lightpush-first staged recovery"),
                contentTopic="/test/1/s18-lightpush-first/proto",
            )
            send_result = sender.send_message(message=message)
            assert send_result.is_ok(), f"send() must return Ok(RequestId) while isolated, got: {send_result.err()}"

            request_id = send_result.ok_value
            assert request_id, "send() returned an empty RequestId"

            # No peers yet: the message must not propagate.
            delay(SERVICE_DOWN_SETTLE_S)
            early_propagated = wait_for_propagated(sender_collector, request_id, timeout_s=0)
            assert early_propagated is None, f"message_propagated arrived before any peer joined: {early_propagated}"

            # Stage 1: lightpush peer appears.
            lightpush_config = {
                **node_config,
                "staticnodes": [get_node_multiaddr(sender)],
                "portsShift": 1,
            }
            lightpush_result = WrapperManager.create_and_start(config=lightpush_config)
            assert lightpush_result.is_ok(), f"Failed to start lightpush peer: {lightpush_result.err()}"

            with lightpush_result.ok_value:
                # Stage 2: relay peer appears.
                relay_config = {
                    **node_config,
                    "lightpush": False,
                    "staticnodes": [get_node_multiaddr(sender)],
                    "portsShift": 2,
                }
                relay_result = WrapperManager.create_and_start(config=relay_config)
                assert relay_result.is_ok(), f"Failed to start relay peer: {relay_result.err()}"

                with relay_result.ok_value:
                    # The message must succeed once any valid path is available.
                    propagated = wait_for_propagated(
                        collector=sender_collector,
                        request_id=request_id,
                        timeout_s=RECOVERY_TIMEOUT_S,
                    )
                    assert propagated is not None, (
                        f"No message_propagated within {RECOVERY_TIMEOUT_S}s "
                        f"after peers appeared in stages. "
                        f"Collected events: {sender_collector.events}"
                    )
                    assert propagated["requestId"] == request_id

                    error = wait_for_error(sender_collector, request_id, timeout_s=0)
                    assert error is None, f"Unexpected message_error after staged recovery: {error}"

                    assert_event_invariants(sender_collector, request_id)

    def test_s18_relay_first_then_lightpush(self, node_config):
        """Sender isolated at T0; relay peer appears, then lightpush peer."""
        sender_collector = EventCollector()

        node_config.update(self._COMMON)

        sender_result = WrapperManager.create_and_start(
            config=node_config,
            event_cb=sender_collector.event_callback,
        )
        assert sender_result.is_ok(), f"Failed to start sender: {sender_result.err()}"

        with sender_result.ok_value as sender:
            # send() before any peer exists must still return Ok(RequestId).
            message = create_message_bindings(
                payload=to_base64("S18 relay-first staged recovery"),
                contentTopic="/test/1/s18-relay-first/proto",
            )
            send_result = sender.send_message(message=message)
            assert send_result.is_ok(), f"send() must return Ok(RequestId) while isolated, got: {send_result.err()}"

            request_id = send_result.ok_value
            assert request_id, "send() returned an empty RequestId"

            # No peers yet: the message must not propagate.
            delay(SERVICE_DOWN_SETTLE_S)
            early_propagated = wait_for_propagated(sender_collector, request_id, timeout_s=0)
            assert early_propagated is None, f"message_propagated arrived before any peer joined: {early_propagated}"

            # Stage 1: relay peer appears.
            relay_config = {
                **node_config,
                "lightpush": False,
                "staticnodes": [get_node_multiaddr(sender)],
                "portsShift": 1,
            }
            relay_result = WrapperManager.create_and_start(config=relay_config)
            assert relay_result.is_ok(), f"Failed to start relay peer: {relay_result.err()}"

            with relay_result.ok_value:
                # Stage 2: lightpush peer appears.
                lightpush_config = {
                    **node_config,
                    "staticnodes": [get_node_multiaddr(sender)],
                    "portsShift": 2,
                }
                lightpush_result = WrapperManager.create_and_start(config=lightpush_config)
                assert lightpush_result.is_ok(), f"Failed to start lightpush peer: {lightpush_result.err()}"

                with lightpush_result.ok_value:
                    # The message must succeed once any valid path is available.
                    propagated = wait_for_propagated(
                        collector=sender_collector,
                        request_id=request_id,
                        timeout_s=RECOVERY_TIMEOUT_S,
                    )
                    assert propagated is not None, (
                        f"No message_propagated within {RECOVERY_TIMEOUT_S}s "
                        f"after peers appeared in stages. "
                        f"Collected events: {sender_collector.events}"
                    )
                    assert propagated["requestId"] == request_id

                    error = wait_for_error(sender_collector, request_id, timeout_s=0)
                    assert error is None, f"Unexpected message_error after staged recovery: {error}"

                    assert_event_invariants(sender_collector, request_id)


class TestS25EphemeralLightpushWithStore(StepsCommon):
    """
    S25 — Ephemeral message over lightpush with a reachable store peer.

    The sender is an Edge node, so it has no local relay and publishes only
    via lightpush. A docker store peer is reachable and joined to the
    lightpush peer's relay mesh, so the message does reach a store.

    Because ephemeral messages are never store-validated, the expected result
    is Propagated only — no Sent — even though the store peer is reachable.
    This is the lightpush-transport counterpart of S24 and proves the
    ephemeral rule is transport-independent.

    Topology mirrors S11:
      [LightpushPeer] wrapper, relay=True, lightpush=True, store=False
      [StorePeer]     docker WakuNode, relay=true, store=true, joined to
                      the lightpush peer's shard-0 relay mesh
      [Edge]          wrapper, mode="Edge", reliabilityEnabled=True,
                      staticnodes=[lightpush_peer, store_peer]
    """

    @pytest.mark.docker_required
    def test_s25_ephemeral_lightpush_with_store(self):
        sender_collector = EventCollector()

        common = {
            "store": False,
            "numShardsInNetwork": 1,
        }

        lightpush_config = build_node_config(
            relay=True,
            lightpush=True,
            **common,
        )

        lightpush_result = WrapperManager.create_and_start(config=lightpush_config)
        assert lightpush_result.is_ok(), f"Failed to start lightpush peer: {lightpush_result.err()}"

        with lightpush_result.ok_value as lightpush_peer:
            lightpush_multiaddr = get_node_multiaddr(lightpush_peer)

            # Docker store peer joined to the lightpush peer's shard-0 relay
            # mesh, so messages propagated by the lightpush peer are archived.
            store_peer = WakuNode(NODE_1, f"s25_store_{self.test_id}")
            store_peer.start(relay="true", store="true")
            self.add_node_peer(store_peer, [lightpush_multiaddr])
            store_peer.set_relay_subscriptions([STORE_PEER_PUBSUB_TOPIC])
            store_multiaddr = store_peer.get_multiaddr_with_id()

            edge_config = build_node_config(
                mode="Edge",
                relay=False,
                staticnodes=[lightpush_multiaddr, store_multiaddr],
                **common,
            )

            edge_result = WrapperManager.create_and_start(
                config=edge_config,
                event_cb=sender_collector.event_callback,
            )
            assert edge_result.is_ok(), f"Failed to start edge sender: {edge_result.err()}"

            with edge_result.ok_value as edge_sender:
                message = create_message_bindings(
                    payload=to_base64("S25 ephemeral lightpush + store payload"),
                    contentTopic="/test/1/s25-ephemeral-lightpush/proto",
                    ephemeral=True,
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

                # Ephemeral messages are never store-validated, so no Sent
                # event must arrive even though the store peer is reachable.
                sent = wait_for_sent(
                    collector=sender_collector,
                    request_id=request_id,
                    timeout_s=NO_SENT_OBSERVATION_S,
                )
                assert sent is None, (
                    f"Unexpected message_sent event for an ephemeral message. "
                    f"Ephemeral messages must never be store-validated.\n"
                    f"Sent event: {sent}\n"
                    f"Collected events: {sender_collector.events}"
                )

                error = wait_for_error(sender_collector, request_id, timeout_s=0)
                assert error is None, f"Unexpected message_error event: {error}"

                assert_event_invariants(sender_collector, request_id)
