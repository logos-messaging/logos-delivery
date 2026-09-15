import pytest
from src.steps.light_push import StepsLightPush


@pytest.mark.usefixtures("setup_main_lightpush_nodes", "subscribe_main_lightpush_nodes")
class TestLightPushPublish(StepsLightPush):
    def test_light_push_after_light_push_node_restarts(self):
        # A sender that neither relays nor serves lightpush reaches the network only through its service peer.
        self.setup_second_lightpush_node(lightpush="false", relay="false")
        self.check_light_pushed_message_reaches_receiving_peer(sender=self.light_push_node2)
        self.light_push_node2.restart()
        self.subscribe_and_light_push_with_retry(sender=self.light_push_node2)

    def test_light_push_after_receiving_node_restarts(self):
        self.check_light_pushed_message_reaches_receiving_peer()
        self.receiving_node1.restart()
        self.subscribe_and_light_push_with_retry()
