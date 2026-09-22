import pytest
from src.steps.metrics import StepsMetrics
from src.steps.relay import StepsRelay


class TestMetrics(StepsRelay, StepsMetrics):
    @pytest.mark.usefixtures("setup_main_relay_nodes", "subscribe_main_relay_nodes", "relay_warm_up")
    def test_metrics_after_relay_publish(self):
        self.node1.send_relay_message(self.create_message(), self.test_pubsub_topic)
        for node in self.main_nodes:
            self.wait_for_metric(node, "libp2p_peers", 1)
            self.wait_for_metric(node, "libp2p_pubsub_peers", 1)
            self.wait_for_metric(node, "libp2p_pubsub_topics", 1)
            self.wait_for_metric(node, "libp2p_pubsub_subscriptions_total", 1)
            self.wait_for_metric(node, 'libp2p_gossipsub_peers_per_topic_mesh{topic="other"}', 1)
            self.wait_for_metric(node, "logos_delivery_peer_store_size", 1)
            self.wait_for_metric(node, "logos_delivery_histogram_message_size_count", 1)
            self.wait_for_metric(node, 'logos_delivery_node_messages_total{type="relay"}', 1)
