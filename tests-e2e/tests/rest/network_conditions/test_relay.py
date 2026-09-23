import pytest
from time import time
from src.env_vars import NODE_1, NODE_2
from src.libs.common import delay, to_base64
from src.node.waku_node import WakuNode
from src.steps.network_conditions import TrafficController
from src.steps.relay import StepsRelay


class TestNetworkConditions(StepsRelay):
    @pytest.fixture(scope="function", autouse=True)
    def traffic_control_setup(self):
        self.tc = TrafficController()

    def start_relay_chain(self, node_count):
        nodes = [WakuNode(NODE_1, f"node1_{self.test_id}")]
        nodes[0].start(relay="true")
        for index in range(2, node_count + 1):
            node = WakuNode(NODE_2, f"node{index}_{self.test_id}")
            node.start(relay="true", discv5_bootstrap_node=nodes[-1].get_enr_uri())
            nodes.append(node)
        for node in nodes:
            node.set_relay_subscriptions([self.test_pubsub_topic])
        for node, bootstrap_node in zip(nodes[1:], nodes):
            self.wait_for_relay_peer(node, bootstrap_node, self.test_pubsub_topic)
        return nodes

    def test_relay_4_nodes_sender_latency(self):
        publisher, *_, receiver = self.start_relay_chain(4)
        latency_seconds = 3
        self.tc.add_latency_p2p_only(publisher, ms=latency_seconds * 1000)

        published_at = time()
        publisher.send_relay_message(self.create_message(), self.test_pubsub_topic)
        self.wait_for_relay_messages(receiver, 1, timeout_duration=60)
        # The message reached the far end of the chain over the delayed link, so it cannot have arrived any sooner.
        assert time() - published_at >= latency_seconds

    def test_relay_4_nodes_sender_packet_loss_uncorrelated_and_correlated(self):
        publisher, *_, receiver = self.start_relay_chain(4)
        # Enough messages that the loss cannot spare every one of them.
        message_count = 30

        self.tc.add_packet_loss_p2p_only(publisher, percent=50.0)
        for _ in range(message_count):
            publisher.send_relay_message(self.create_message(), self.test_pubsub_topic)
        self.wait_for_relay_messages(receiver, message_count, timeout_duration=60)
        # The loss is on the relay path: the qdisc that carried the messages is the one dropping packets.
        assert self.tc.dropped_packets_p2p(publisher) > 0

        self.tc.add_packet_loss_correlated_p2p_only(publisher, percent=50.0, correlation=75.0)
        for _ in range(message_count):
            publisher.send_relay_message(self.create_message(), self.test_pubsub_topic)
        self.wait_for_relay_messages(receiver, message_count, timeout_duration=60)
        assert self.tc.dropped_packets_p2p(publisher) > 0

    def test_relay_2_nodes_low_bandwidth_reliability(self):
        publisher, receiver = self.start_relay_chain(2)
        message_count = 50
        payload_bytes = 16_000
        rate_kbit = 256
        self.tc.add_bandwidth_p2p_only(publisher, rate=f"{rate_kbit}kbit")

        published_at = time()
        for _ in range(message_count):
            publisher.send_relay_message(self.create_message(payload=to_base64("x" * payload_bytes)), self.test_pubsub_topic)
        self.wait_for_relay_messages(receiver, message_count, timeout_duration=120)
        # Every message crossed the narrow link, so they cannot have arrived faster than its rate carries their bytes.
        assert time() - published_at >= message_count * payload_bytes * 8 / (rate_kbit * 1000)

    def test_relay_2_nodes_temporary_blackout_recovers(self):
        publisher, receiver = self.start_relay_chain(2)
        message_count = 100
        self.tc.add_packet_loss_p2p_only(publisher, percent=100.0)
        self.tc.add_packet_loss_p2p_only(receiver, percent=100.0)
        # Nothing observable marks the outage: it lasts as long as the test holds it.
        delay(5)
        self.tc.clear_p2p(publisher)
        self.tc.clear_p2p(receiver)

        self.wait_for_relay_peer(publisher, receiver, self.test_pubsub_topic)
        self.wait_for_relay_peer(receiver, publisher, self.test_pubsub_topic)
        for _ in range(message_count):
            publisher.send_relay_message(self.create_message(), self.test_pubsub_topic)
        self.wait_for_relay_messages(receiver, message_count, timeout_duration=60)
