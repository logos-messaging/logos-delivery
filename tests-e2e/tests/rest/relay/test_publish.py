import pytest
from time import time
from src.libs.common import delay, to_base64
from src.steps.relay import StepsRelay


@pytest.mark.usefixtures("setup_main_relay_nodes", "subscribe_main_relay_nodes", "relay_warm_up")
class TestRelayPublish(StepsRelay):
    def test_publish_after_node2_restarts(self):
        self.check_published_message_reaches_relay_peer()
        self.node2.restart()
        self.ensure_relay_subscriptions_on_nodes(self.main_nodes, [self.test_pubsub_topic])
        self.wait_for_published_message_to_reach_relay_peer()

    def test_publish_and_retrieve_100_messages(self):
        num_messages = 100  # if increase this number make sure to also increase rest-relay-cache-capacity flag
        for index in range(num_messages):
            message = self.create_message(payload=to_base64(f"M_{index}"))
            self.node1.send_relay_message(message, self.test_pubsub_topic)
        messages = []
        deadline = time() + 10
        while len(messages) < num_messages and time() < deadline:
            messages.extend(self.node2.get_relay_messages(self.test_pubsub_topic))
            delay(0.1)
        assert len(messages) == num_messages
        received_payloads = {message["payload"] for message in messages}
        expected_payloads = {to_base64(f"M_{index}") for index in range(num_messages)}
        assert received_payloads == expected_payloads
