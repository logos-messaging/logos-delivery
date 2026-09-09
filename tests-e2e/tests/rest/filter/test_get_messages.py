import pytest
from src.libs.common import delay
from src.steps.filter import StepsFilter


# here we will also implicitly test filter push, see: https://rfc.vac.dev/spec/12/#messagepush
@pytest.mark.usefixtures("setup_main_relay_node", "setup_main_filter_node", "subscribe_main_nodes")
class TestFilterGetMessages(StepsFilter):
    def test_filter_get_message_after_node1_restarts(self):
        self.check_published_message_reaches_filter_peer()
        self.node1.restart()
        self.node1.ensure_ready()
        delay(2)
        self.wait_for_subscriptions_on_main_nodes([self.test_content_topic])
        self.check_published_message_reaches_filter_peer()

    def test_filter_get_message_after_node2_restarts(self):
        self.check_published_message_reaches_filter_peer()
        self.node2.restart()
        self.node2.ensure_ready()
        delay(2)
        self.wait_for_subscriptions_on_main_nodes([self.test_content_topic])
        self.check_published_message_reaches_filter_peer()
