import pytest
from src.steps.relay import StepsRelay


@pytest.mark.usefixtures("setup_main_relay_nodes", "setup_optional_relay_nodes", "subscribe_main_relay_nodes")
class TestRelayMultipleNodes(StepsRelay):
    @pytest.mark.smoke
    def test_first_node_to_start_publishes(self, subscribe_optional_relay_nodes, relay_warm_up):
        self.check_published_message_reaches_relay_peer()

    def test_last_node_to_start_publishes(self, subscribe_optional_relay_nodes, relay_warm_up):
        self.check_published_message_reaches_relay_peer(sender=self.optional_nodes[-1])

    def test_relay_get_message_while_one_peer_is_paused(self, subscribe_optional_relay_nodes, relay_warm_up):
        self.check_published_message_reaches_relay_peer()
        relay_message1 = self.create_message(contentTopic=self.test_content_topic)
        relay_message2 = self.create_message(contentTopic=self.test_content_topic)
        self.node2.pause()
        self.node1.send_relay_message(relay_message1, self.test_pubsub_topic)
        self.node2.unpause()
        self.node1.send_relay_message(relay_message2, self.test_pubsub_topic)
        messages = self.node2.get_relay_messages(self.test_pubsub_topic)
        assert len(messages) == 2, "Both messages should've been returned"
