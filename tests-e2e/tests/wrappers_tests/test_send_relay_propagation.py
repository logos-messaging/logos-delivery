from src.steps.common import StepsCommon
from src.libs.common import to_base64
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
from src.test_data import CONTENT_TOPICS_DIFFERENT_SHARDS


PROPAGATED_TIMEOUT_S = 30.0


class TestS29SendOnTopicsMappingToDifferentShards(StepsCommon):
    """
    S29 — Send on two different content topics that map to different shards.
    Sender has a relay peer reachable on shard X and shard Y; topic A maps to
    shard X and topic B maps to shard Y. Two independent sends, one per topic.
    Expected: both sends return Ok(RequestId), and each request gets its own
    message_propagated event following the availability of its own shard.
    Purpose: ensures shard derivation and delivery behavior are topic-specific.
    """

    # Topic A -> shard 0, Topic B -> shard 1 (per CONTENT_TOPICS_DIFFERENT_SHARDS).
    TOPIC_A = CONTENT_TOPICS_DIFFERENT_SHARDS[0]
    TOPIC_B = CONTENT_TOPICS_DIFFERENT_SHARDS[1]

    def test_s29_send_on_topics_mapping_to_different_shards(self, node_config):
        sender_collector = EventCollector()

        # numShardsInNetwork=8 so the two topics resolve to distinct shards
        # (shard 0 and shard 1) instead of being collapsed onto shard 0.
        node_config.update(
            {
                "relay": True,
                "store": False,
                "lightpush": False,
                "filter": False,
                "discv5Discovery": False,
                "numShardsInNetwork": 8,
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
                "portsShift": 1,
            }

            peer_result = WrapperManager.create_and_start(config=peer_config)
            assert peer_result.is_ok(), f"Failed to start relay peer: {peer_result.err()}"

            with peer_result.ok_value:
                assert wait_for_connected(sender_collector) is not None, "Sender did not reach Connected/PartiallyConnected state"

                message_a = create_message_bindings(
                    payload=to_base64("S29 shard X payload"),
                    contentTopic=self.TOPIC_A,
                )
                send_a = sender.send_message(message=message_a)
                assert send_a.is_ok(), f"send() on TOPIC_A failed: {send_a.err()}"
                request_id_a = send_a.ok_value
                assert request_id_a, "send() on TOPIC_A returned an empty RequestId"

                # Send on topic B (shard Y).
                message_b = create_message_bindings(
                    payload=to_base64("S29 shard Y payload"),
                    contentTopic=self.TOPIC_B,
                )
                send_b = sender.send_message(message=message_b)
                assert send_b.is_ok(), f"send() on TOPIC_B failed: {send_b.err()}"
                request_id_b = send_b.ok_value
                assert request_id_b, "send() on TOPIC_B returned an empty RequestId"

                assert request_id_a != request_id_b, "Each send must produce a distinct RequestId"

                # Each request propagates over its own shard's mesh independently.
                propagated_a = wait_for_propagated(
                    collector=sender_collector,
                    request_id=request_id_a,
                    timeout_s=PROPAGATED_TIMEOUT_S,
                )
                assert propagated_a is not None, (
                    f"No message_propagated event for TOPIC_A within {PROPAGATED_TIMEOUT_S}s. " f"Collected events: {sender_collector.events}"
                )
                assert propagated_a["requestId"] == request_id_a

                propagated_b = wait_for_propagated(
                    collector=sender_collector,
                    request_id=request_id_b,
                    timeout_s=PROPAGATED_TIMEOUT_S,
                )
                assert propagated_b is not None, (
                    f"No message_propagated event for TOPIC_B within {PROPAGATED_TIMEOUT_S}s. " f"Collected events: {sender_collector.events}"
                )
                assert propagated_b["requestId"] == request_id_b

                # No cross-talk: neither request should produce an error.
                for request_id in (request_id_a, request_id_b):
                    error = wait_for_error(sender_collector, request_id, timeout_s=0)
                    assert error is None, f"Unexpected message_error event for {request_id}: {error}"

                assert_event_invariants(sender_collector, request_id_a)
                assert_event_invariants(sender_collector, request_id_b)
