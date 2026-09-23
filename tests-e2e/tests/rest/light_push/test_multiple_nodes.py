from src.env_vars import NODE_1, NODE_2
from src.libs.common import wait_until
from src.node.waku_node import WakuNode
from src.steps.light_push import StepsLightPush
from src.steps.store import StepsStore


class TestLightPushMultipleNodes(StepsLightPush, StepsStore):
    def test_2_receiving_nodes_relay_node1_forwards_lightpushed_message_to_filter_node2(self):
        self.setup_first_receiving_node(lightpush="true", relay="true", filter="true")
        self.setup_second_receiving_node(lightpush="false", relay="false", filternode=self.receiving_node1.get_multiaddr_with_id())
        self.setup_first_lightpush_node(lightpush="true", relay="true")
        receiving_node4 = self.start_receiving_node(NODE_1, node_index=4, lightpush="false", relay="true")
        self.subscribe_to_pubsub_topics_via_relay(node=[self.receiving_node1, receiving_node4])
        self.subscribe_to_pubsub_topics_via_filter(node=self.receiving_node2)
        self.check_light_pushed_message_reaches_receiving_peer(sender=self.light_push_node1)
        get_messages_response = wait_until(lambda: self.receiving_node2.get_filter_messages(self.test_content_topic))
        assert len(get_messages_response) == 1, "Lightpushed message was not relayed to the filter node"

    def test_multiple_edge_service_nodes_communication(self):
        self.service_node1 = WakuNode(NODE_2, f"service_node1_{self.test_id}")
        self.service_node2 = WakuNode(NODE_1, f"service_node2_{self.test_id}")
        self.service_node3 = WakuNode(NODE_2, f"service_node3_{self.test_id}")
        self.edge_node1 = WakuNode(NODE_1, f"edge_node1_{self.test_id}")
        self.edge_node2 = WakuNode(NODE_1, f"edge_node2_{self.test_id}")

        self.service_node1.start(relay="true", store="true", lightpush="true")
        self.service_node2.start(relay="true", store="true", discv5_bootstrap_node=self.service_node1.get_enr_uri())
        self.service_node3.start(
            relay="true",
            filter="true",
            storenode=self.service_node2.get_multiaddr_with_id(),
            discv5_bootstrap_node=self.service_node2.get_enr_uri(),
        )
        self.edge_node1.start(
            relay="false",
            lightpushnode=self.service_node1.get_multiaddr_with_id(),
            discv5_bootstrap_node=self.service_node1.get_enr_uri(),
        )
        self.edge_node2.start(
            relay="false",
            filternode=self.service_node3.get_multiaddr_with_id(),
            storenode=self.service_node2.get_multiaddr_with_id(),
            discv5_bootstrap_node=self.service_node2.get_enr_uri(),
        )

        self.subscribe_to_pubsub_topics_via_relay(node=[self.service_node1, self.service_node2, self.service_node3])
        self.wait_for_relay_peer(self.service_node2, self.service_node1, self.test_pubsub_topic)
        self.wait_for_relay_peer(self.service_node3, self.service_node2, self.test_pubsub_topic)
        self.subscribe_to_pubsub_topics_via_filter(node=self.edge_node2)

        message = self.create_message()
        self.check_light_pushed_message_reaches_receiving_peer(sender=self.edge_node1, peer_list=[self.service_node1], message=message)
        self.wait_for_published_message_is_stored(
            store_node=[self.edge_node2, self.service_node3], messages_to_check=[message], page_size=50, ascending="true"
        )
        get_messages_response = wait_until(lambda: self.edge_node2.get_filter_messages(self.test_content_topic))
        assert len(get_messages_response) == 1, "Lightpushed message did not reach the filter client of the third service node"
