import pytest
from src.steps.store import StepsStore


@pytest.mark.usefixtures("node_setup")
class TestReliability(StepsStore):
    def test_store_node_restarts(self):
        self.publish_message(message_propagation_delay=0)
        self.wait_for_published_message_is_stored(page_size=5)
        self.store_node1.restart()
        self.subscribe_to_pubsub_topics_via_relay(node=self.store_node1)
        self.wait_for_relay_peer(self.publishing_node1, self.store_node1, self.test_pubsub_topic)
        self.publish_message(message_propagation_delay=0)
        self.wait_for_published_message_is_stored(page_size=5)
        for node in self.store_nodes:
            store_response = self.get_messages_from_store(node, page_size=5)
            assert len(store_response.messages) == 2
