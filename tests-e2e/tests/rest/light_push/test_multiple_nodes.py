from src.env_vars import NODE_1
from src.libs.common import wait_until
from src.steps.light_push import StepsLightPush


class TestLightPushMultipleNodes(StepsLightPush):
    def test_2_receiving_nodes__relay_node1_forwards_lightpushed_message_to_filter_node2(self):
        self.setup_first_receiving_node(lightpush="true", relay="true", filter="true")
        self.setup_second_receiving_node(lightpush="false", relay="false", filternode=self.receiving_node1.get_multiaddr_with_id())
        self.setup_first_lightpush_node(lightpush="true", relay="true")
        helper_node = self.start_receiving_node(NODE_1, node_index=4, lightpush="false", relay="true")
        self.subscribe_to_pubsub_topics_via_relay(node=[self.receiving_node1, helper_node])
        self.subscribe_to_pubsub_topics_via_filter(node=self.receiving_node2)
        self.check_light_pushed_message_reaches_receiving_peer(sender=self.light_push_node1)
        get_messages_response = wait_until(lambda: self.receiving_node2.get_filter_messages(self.test_content_topic))
        assert len(get_messages_response) == 1, "Lightpushed message was not relayed to the filter node"
