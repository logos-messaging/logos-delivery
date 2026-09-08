import pytest
from src.env_vars import NODE_1, NODE_2
from src.libs.common import delay
from src.libs.custom_logger import get_custom_logger
from src.node.waku_node import WakuNode
from src.steps.filter import StepsFilter
from src.steps.light_push import StepsLightPush
from src.steps.relay import StepsRelay
from src.steps.store import StepsStore

logger = get_custom_logger(__name__)

"""
In those tests we aim to combine multiple protocols/node types and create a more end-to-end scenario
"""


class TestE2E(StepsFilter, StepsStore, StepsRelay, StepsLightPush):
    @pytest.fixture(scope="function", autouse=True)
    def nodes(self):
        self.node1 = WakuNode(NODE_2, f"node1_{self.test_id}")
        self.node2 = WakuNode(NODE_1, f"node2_{self.test_id}")
        self.node3 = WakuNode(NODE_2, f"node3_{self.test_id}")

    @pytest.mark.smoke
    @pytest.mark.slow
    def test_store_filter_interaction_with_six_nodes(self):
        logger.debug("Create  6 nodes")
        self.node4 = WakuNode(NODE_2, f"node4_{self.test_id}")
        self.node5 = WakuNode(NODE_2, f"node5_{self.test_id}")
        self.node6 = WakuNode(NODE_2, f"node6_{self.test_id}")

        logger.debug("Start 5 nodes with their corresponding config")
        self.node1.start(relay="true", store="true")
        self.node2.start(relay="true", store="true", discv5_bootstrap_node=self.node1.get_enr_uri())
        self.node3.start(relay="true", store="true", discv5_bootstrap_node=self.node2.get_enr_uri())
        self.node4.start(relay="true", filter="true", store="true", discv5_bootstrap_node=self.node3.get_enr_uri())
        self.node6.start(relay="false", filternode=self.node4.get_multiaddr_with_id(), discv5_bootstrap_node=self.node4.get_enr_uri())

        logger.debug("Subscribe nodes to relay  pubsub topics")
        node_list = [self.node1, self.node2, self.node3, self.node4]
        for node in node_list:
            node.set_relay_subscriptions([self.test_pubsub_topic])

        logger.debug(f"Node6 subscribe to filter for pubsubtopic {self.test_pubsub_topic}")
        node_list.append(self.node6)
        self.node6.set_filter_subscriptions({"requestId": "1", "contentFilters": [self.test_content_topic], "pubsubTopic": self.test_pubsub_topic})
        self.wait_for_autoconnection(node_list, hard_wait=50)

        logger.debug(f"Node1 publish message for topic {self.test_pubsub_topic}")
        message = self.create_message()
        self.publish_message(sender=self.node1, pubsub_topic=self.test_pubsub_topic, message=message)
        delay(4)

        logger.debug(f"Node6 inquery for filter messages on pubsubtopic {self.test_pubsub_topic} & contenttopic{self.test_content_topic}")
        messages_response = self.get_filter_messages(self.test_content_topic, pubsub_topic=self.test_pubsub_topic, node=self.node6)
        logger.debug(f"Filter inquiry response is {messages_response}")
        assert len(messages_response) == 1, f"filtered messages count doesn't match published messages"

        logger.debug("Node5 goes live !!")
        self.node5.start(relay="false", storenode=self.node4.get_multiaddr_with_id(), discv5_bootstrap_node=self.node4.get_enr_uri())
        delay(2)
        logger.debug("Node5 makes request to get stored messages ")
        self.check_published_message_is_stored(page_size=50, ascending="true", store_node=self.node5, messages_to_check=[message])
