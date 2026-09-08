import pytest
from src.steps.relay import StepsRelay


@pytest.mark.usefixtures("setup_main_relay_nodes", "setup_optional_relay_nodes", "subscribe_main_relay_nodes")
class TestRelayMultipleNodes(StepsRelay):
    @pytest.mark.smoke
    def test_first_node_to_start_publishes(self, subscribe_optional_relay_nodes, relay_warm_up):
        self.check_published_message_reaches_relay_peer()
