import pytest
from time import time
from src.libs.common import delay, to_base64
from src.steps.light_push import StepsLightPush


class TestLightPushPublish(StepsLightPush):
    @pytest.fixture(scope="function", autouse=True)
    def light_push_publish_setup(self, light_push_setup):
        self.setup_first_receiving_node()
        self.setup_second_receiving_node(lightpush="false", relay="true")
        self.setup_first_lightpush_node()
        self.subscribe_to_pubsub_topics_via_relay()

    def test_light_push_after_light_push_node_restarts(self):
        # A sender that neither relays nor serves lightpush reaches the network only through its service peer.
        self.setup_first_lightpush_node(lightpush="false", relay="false")
        self.check_light_pushed_message_reaches_receiving_peer()
        self.light_push_node1.restart()
        self.light_push_node1.ensure_ready()
        self.check_light_pushed_message_reaches_receiving_peer()

    def test_light_push_after_receiving_node_restarts(self):
        self.check_light_pushed_message_reaches_receiving_peer()
        self.receiving_node1.restart()
        self.receiving_node1.ensure_ready()
        self.subscribe_and_light_push_with_retry()

    @pytest.mark.slow
    def test_light_push_and_retrieve_100_messages(self):
        num_messages = 100  # if increase this number make sure to also increase rest-relay-cache-capacity flag
        for index in range(num_messages):
            message = self.create_message(payload=to_base64(f"M_{index}"))
            self.light_push_node1.send_light_push_message(self.create_payload(message=message))
            delay(0.3)  # the service answers 429 above 5 lightpush requests per second
        messages = []
        deadline = time() + 10
        while len(messages) < num_messages and time() < deadline:
            messages.extend(self.receiving_node1.get_relay_messages(self.test_pubsub_topic))
            delay(0.1)
        assert len(messages) == num_messages
        received_payloads = {message["payload"] for message in messages}
        expected_payloads = {to_base64(f"M_{index}") for index in range(num_messages)}
        assert received_payloads == expected_payloads
