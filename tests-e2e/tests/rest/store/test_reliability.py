import pytest
from src.steps.metrics import StepsMetrics
from src.steps.store import StepsStore


@pytest.mark.usefixtures("node_setup")
class TestReliability(StepsStore, StepsMetrics):
    def test_store_node_restarts(self):
        self.publish_message(message_propagation_delay=0)
        self.wait_for_published_message_is_stored(page_size=5)
        # Once the message leaves the gossip window, the restarted node can only read it from its own archive.
        self.wait_for_metric(self.publishing_node1, "libp2p_gossipsub_cache_window_size", 0, exact=True)
        self.store_node1.restart()
        self.wait_for_relay_peer(self.publishing_node1, self.store_node1, self.test_pubsub_topic)
        self.publish_message(message_propagation_delay=0)
        self.wait_for_published_message_is_stored(page_size=5)
        for node in self.store_nodes:
            store_response = self.get_messages_from_store(node, page_size=5)
            assert len(store_response.messages) == 2
