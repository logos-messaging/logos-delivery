import pytest
from src.libs.common import delay, to_base64, wait_until
from src.steps.light_push import StepsLightPush


@pytest.mark.usefixtures("setup_main_lightpush_nodes", "subscribe_main_lightpush_nodes")
class TestLightPushPublish(StepsLightPush):
    def test_light_push_after_light_push_node_restarts(self):
        # A sender that neither relays nor serves lightpush reaches the network only through its service peer.
        self.setup_second_lightpush_node(lightpush="false", relay="false")
        self.check_light_pushed_message_reaches_receiving_peer(sender=self.light_push_node2)
        self.light_push_node2.restart()
        self.light_push_node2.ensure_ready()
        self.subscribe_and_light_push_with_retry(sender=self.light_push_node2)

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

        def enough_messages_received():
            messages.extend(self.receiving_node1.get_relay_messages(self.test_pubsub_topic))
            return len(messages) >= num_messages

        wait_until(enough_messages_received, timeout_duration=10, time_between_retries=0.1)
        assert len(messages) == num_messages
        received_payloads = {message["payload"] for message in messages}
        expected_payloads = {to_base64(f"M_{index}") for index in range(num_messages)}
        assert received_payloads == expected_payloads
