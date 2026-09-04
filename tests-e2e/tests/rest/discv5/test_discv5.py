import pytest

from src.env_vars import NODE_1, NODE_2
from src.node.waku_node import WakuNode
from src.steps.filter import StepsFilter
from src.steps.light_push import StepsLightPush
from src.steps.relay import StepsRelay
from src.steps.store import StepsStore
from tenacity import retry, stop_after_delay, wait_fixed


class TestDiscv5(StepsRelay, StepsFilter, StepsStore, StepsLightPush):
    def running_a_node(self, image, **kwargs):
        node = WakuNode(image, f"node{len(self.main_nodes) + 1}_{self.test_id}")
        node.start(**kwargs)
        return node

    @retry(stop=stop_after_delay(70), wait=wait_fixed(1), reraise=True)
    def wait_for_light_pushed_message_to_reach_receiving_peer(self):
        self.check_light_pushed_message_reaches_receiving_peer(peer_list=[self.receiving_node1, self.receiving_node2])

    @pytest.mark.smoke
    def test_relay(self):
        self.node1 = self.running_a_node(NODE_1, relay="true")
        self.node2 = self.running_a_node(NODE_2, relay="true", discv5_bootstrap_node=self.node1.get_enr_uri())
        self.main_nodes = [self.node1, self.node2]
        self.ensure_relay_subscriptions_on_nodes(self.main_nodes, [self.test_pubsub_topic])
        self.wait_for_published_message_to_reach_relay_peer()

    @pytest.mark.smoke
    def test_filter(self):
        self.node1 = self.running_a_node(NODE_1, relay="true", filter="true")
        self.node2 = self.running_a_node(
            NODE_2, relay="false", discv5_bootstrap_node=self.node1.get_enr_uri(), filternode=self.node1.get_multiaddr_with_id()
        )
        self.main_nodes = [self.node2]
        self.wait_for_subscriptions_on_main_nodes([self.test_content_topic])
        self.check_published_message_reaches_filter_peer()

    @pytest.mark.smoke
    def test_lightpush(self):
        self.receiving_node1 = self.running_a_node(NODE_1, lightpush="true", relay="true")
        self.receiving_node2 = self.running_a_node(NODE_1, lightpush="false", relay="true", discv5_bootstrap_node=self.receiving_node1.get_enr_uri())
        self.light_push_node1 = self.running_a_node(
            NODE_2,
            lightpush="true",
            relay="true",
            discv5_bootstrap_node=self.receiving_node1.get_enr_uri(),
            lightpushnode=self.receiving_node1.get_multiaddr_with_id(),
        )
        self.subscribe_to_pubsub_topics_via_relay([self.receiving_node1, self.receiving_node2])
        self.wait_for_light_pushed_message_to_reach_receiving_peer()
