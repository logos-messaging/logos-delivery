"""RC10 outcome: SDS-R repair recovers a missing dependency.

Marked `slow` and kept out of the CI selection: the repair request only rides
out after T_req, so the test spends minutes waiting. The CI-safe setup half is
test_rc10_missing_dependency_is_parked in test_channel_delivery.py.
"""

import time

import pytest

from src.libs.common import delay, to_base64
from src.node.subprocess_node import ChannelSenderProcess
from src.node.wrappers_manager import WrapperManager
from src.node.wrapper_helpers import EventCollector, create_message_bindings, get_node_multiaddr, unique_channel_id
from tests.wrappers_tests.test_channel_delivery import (
    CHANNEL_RECEIVED_EVENT,
    DELIVERY_TIMEOUT_S,
    MESH_SETTLE_S,
    MESSAGE_RECEIVED_EVENT,
    NO_CHANNEL_DELIVERY_WINDOW_S,
    RC10_CHANNEL_PREFIX,
    RC10_CHANNEL_SETTLE_S,
    RC10_CONTENT_TOPIC,
    SENDER_A,
    SENDER_B,
    channel_payloads,
    wait_for_channel_received,
    wait_for_channel_received_count,
    wait_for_distinct_message_received,
    wait_for_message_received,
)

# A repair request only rides out attached to an outgoing message, so B keeps
# sending until T_req has elapsed for m1.
NUDGE_INTERVAL_S = 10.0
REPAIR_TIMEOUT_S = 330.0


@pytest.mark.slow
class TestChannelRepair:
    @pytest.mark.timeout(REPAIR_TIMEOUT_S + 120)
    def test_rc10_repair_delivers_missing_dependency(self, node_config):
        """RC10: B parks m2 on the missing m1, then recovers both in causal order.

        B has no channel when A sends m1, so m1 is lost to B's SDS and m2 arrives
        referencing it. B keeps sending until one of its messages carries the
        repair request and A rebroadcasts m1.
        """
        channel_id = unique_channel_id(RC10_CHANNEL_PREFIX)
        m1, m2 = "rc10 sent before B has a channel", "rc10 depends on m1"

        node_config.update(
            {
                "relay": True,
                "store": False,
                "reliabilityEnabled": False,
                "numShardsInNetwork": 1,
            }
        )

        receiver_collector = EventCollector()
        receiver_result = WrapperManager.create_and_start(config=node_config, event_cb=receiver_collector.event_callback)
        assert receiver_result.is_ok(), f"Failed to start receiver: {receiver_result.err()}"

        with receiver_result.ok_value as receiver:
            sender_config = {
                **node_config,
                "staticnodes": [get_node_multiaddr(receiver)],
                "portsShift": 1,
            }

            subscribe_result = receiver.subscribe_content_topic(RC10_CONTENT_TOPIC)
            assert subscribe_result.is_ok(), f"receiver subscribe_content_topic failed: {subscribe_result.err()}"

            with ChannelSenderProcess(
                sender_config,
                content_topic=RC10_CONTENT_TOPIC,
                channel_id=channel_id,
                sender_id=SENDER_A,
                payload_b64=to_base64(m1),
                settle_s=MESH_SETTLE_S,
            ) as sender:
                arrived = wait_for_message_received(receiver_collector, RC10_CONTENT_TOPIC, DELIVERY_TIMEOUT_S)
                assert arrived is not None, (
                    f"receiver never saw a {MESSAGE_RECEIVED_EVENT} for m1 within {DELIVERY_TIMEOUT_S}s; "
                    f"the dependency was never established. Collected events: {receiver_collector.snapshot()}"
                )

                receiver_create = receiver.channel_create(channel_id, RC10_CONTENT_TOPIC, SENDER_B)
                assert receiver_create.is_ok(), f"receiver channel_create failed: {receiver_create.err()}"

                delay(RC10_CHANNEL_SETTLE_S)

                sender.send(to_base64(m2))

                both = wait_for_distinct_message_received(receiver_collector, RC10_CONTENT_TOPIC, 2, DELIVERY_TIMEOUT_S)
                assert len(both) == 2, (
                    f"receiver must see m2 at the messaging layer within {DELIVERY_TIMEOUT_S}s; "
                    f"got {len(both)} distinct {MESSAGE_RECEIVED_EVENT} envelopes. "
                    f"Collected events: {receiver_collector.snapshot()}"
                )

                parked = wait_for_channel_received(receiver_collector, channel_id, NO_CHANNEL_DELIVERY_WINDOW_S)
                assert parked is None, f"m2 must park on the missing m1, not surface as {CHANNEL_RECEIVED_EVENT}; got: {parked!r}"

                recovered = []
                deadline = time.monotonic() + REPAIR_TIMEOUT_S
                while len(recovered) < 2 and time.monotonic() < deadline:
                    nudge_result = receiver.channel_send(channel_id, create_message_bindings(payload=to_base64("rc10 nudge")))
                    assert nudge_result.is_ok(), f"receiver channel_send failed: {nudge_result.err()}"
                    recovered = wait_for_channel_received_count(receiver_collector, channel_id, 2, NUDGE_INTERVAL_S)

                assert channel_payloads(recovered) == [m1.encode(), m2.encode()], (
                    f"the repair must deliver m1, releasing m2 behind it; got {channel_payloads(recovered)!r} "
                    f"after {REPAIR_TIMEOUT_S}s. Collected events: {receiver_collector.snapshot()}"
                )
