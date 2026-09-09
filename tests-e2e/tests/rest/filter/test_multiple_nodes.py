import pytest
from src.libs.common import delay
from src.steps.filter import StepsFilter


@pytest.mark.usefixtures("setup_main_relay_node", "setup_main_filter_node")
class TestFilterMultipleNodes(StepsFilter):
    def test_filter_get_message_while_one_peer_is_paused(self):
        self.setup_optional_filter_nodes()
        self.wait_for_subscriptions_on_main_nodes([self.test_content_topic])
        self.subscribe_optional_filter_nodes([self.test_content_topic])
        self.check_published_message_reaches_filter_peer()
        relay_message1 = self.create_message(contentTopic=self.test_content_topic)
        relay_message2 = self.create_message(contentTopic=self.test_content_topic)
        self.node2.pause()
        self.node1.send_relay_message(relay_message1, self.test_pubsub_topic)
        self.node2.unpause()
        self.node1.send_relay_message(relay_message2, self.test_pubsub_topic)
        delay(0.5)
        filter_messages = self.get_filter_messages(content_topic=self.test_content_topic, pubsub_topic=self.test_pubsub_topic, node=self.node2)
        assert len(filter_messages) == 2, "Both messages should've been returned"
