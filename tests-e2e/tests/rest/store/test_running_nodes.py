from src.env_vars import NODE_1, NODE_2
from src.libs.common import wait_until
from src.node.waku_node import WakuNode
from src.steps.store import StepsStore


class TestRunningNodes(StepsStore):
    def test_store_lightpushed_message(self):
        self.setup_first_publishing_node(store="true", relay="true", lightpush="true")
        self.setup_second_publishing_node(store="false", relay="true")
        self.setup_first_store_node(store="false", relay="true", lightpush="true", lightpushnode=self.multiaddr_list[0])
        self.subscribe_to_pubsub_topics_via_relay()
        self.publish_message(via="lightpush", sender=self.store_node1)
        self.check_published_message_is_stored(page_size=5, ascending="true")

    def test_store_filter_interaction_with_six_nodes(self):
        self.node1 = WakuNode(NODE_2, f"node1_{self.test_id}")
        self.node2 = WakuNode(NODE_1, f"node2_{self.test_id}")
        self.node3 = WakuNode(NODE_2, f"node3_{self.test_id}")
        self.node4 = WakuNode(NODE_2, f"node4_{self.test_id}")
        self.node5 = WakuNode(NODE_2, f"node5_{self.test_id}")
        self.node6 = WakuNode(NODE_2, f"node6_{self.test_id}")

        self.node1.start(relay="true", store="true")
        self.node2.start(relay="true", store="true", discv5_bootstrap_node=self.node1.get_enr_uri())
        self.node3.start(relay="true", store="true", discv5_bootstrap_node=self.node2.get_enr_uri())
        self.node4.start(relay="true", filter="true", store="true", discv5_bootstrap_node=self.node3.get_enr_uri())
        self.node6.start(relay="false", filternode=self.node4.get_multiaddr_with_id(), discv5_bootstrap_node=self.node4.get_enr_uri())

        relay_nodes = [self.node1, self.node2, self.node3, self.node4]
        self.subscribe_to_pubsub_topics_via_relay(node=relay_nodes)
        self.subscribe_to_pubsub_topics_via_filter(node=self.node6)
        for node, bootstrap_node in zip(relay_nodes[1:], relay_nodes):
            self.wait_for_relay_peer(node, bootstrap_node, self.test_pubsub_topic)

        message = self.publish_message(sender=self.node1, message_propagation_delay=0)
        get_messages_response = wait_until(lambda: self.node6.get_filter_messages(self.test_content_topic))
        assert len(get_messages_response) == 1, "The filter client did not receive the relayed message"

        self.node5.start(relay="false", storenode=self.node4.get_multiaddr_with_id(), discv5_bootstrap_node=self.node4.get_enr_uri())
        self.wait_for_published_message_is_stored(store_node=self.node5, messages_to_check=[message], page_size=50, ascending="true")
