import pytest
from src.steps.relay import StepsRelay


@pytest.mark.usefixtures("setup_main_relay_nodes")
class TestRelaySubscribe(StepsRelay):
    @pytest.mark.smoke
    def test_relay_subscribe_to_single_pubsub_topic(self):
        self.ensure_relay_subscriptions_on_nodes(self.main_nodes, [self.test_pubsub_topic])
        self.wait_for_published_message_to_reach_relay_peer()
