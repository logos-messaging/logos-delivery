import inspect
from src.libs.custom_logger import get_custom_logger
from time import time
import pytest
import allure
from src.libs.common import to_base64, delay
from src.node.waku_message import WakuMessage
from src.env_vars import (
    ADDITIONAL_NODES,
    NODE_1,
    NODE_2,
)
from src.node.waku_node import WakuNode
from src.steps.common import StepsCommon
from src.test_data import VALID_PUBSUB_TOPICS
from tenacity import retry, stop_after_delay, wait_fixed

logger = get_custom_logger(__name__)


class StepsLightPush(StepsCommon):
    test_content_topic = "/myapp/1/latest/proto"
    test_pubsub_topic = VALID_PUBSUB_TOPICS[0]
    test_payload = "Light push works!!"
    default_message_propagation_delay = 0.1
    num_shards_in_network = 8

    @pytest.fixture(scope="function", autouse=True)
    def light_push_setup(self):
        logger.debug(f"Running fixture setup: {inspect.currentframe().f_code.co_name}")
        self.main_receiving_nodes = []
        self.optional_nodes = []
        self.multiaddr_list = []

    @allure.step
    def start_receiving_node(self, image, node_index, **kwargs):
        node = WakuNode(image, f"receiving_node{node_index}_{self.test_id}")
        node.start(**kwargs)
        if kwargs["relay"] == "true":
            self.main_receiving_nodes.extend([node])
        self.add_node_peer(node, self.multiaddr_list)
        self.multiaddr_list.extend([node.get_multiaddr_with_id()])
        return node

    @allure.step
    def setup_lightpush_node(self, image, node_index, **kwargs):
        node = WakuNode(image, f"lightpush_node{node_index}_{self.test_id}")
        node.start(discv5_bootstrap_node=self.enr_uri, lightpushnode=self.multiaddr_list[0], **kwargs)
        if kwargs["relay"] == "true":
            self.main_receiving_nodes.extend([node])
        self.add_node_peer(node, self.multiaddr_list)
        return node

    @allure.step
    def setup_first_receiving_node(self, lightpush="true", relay="true", **kwargs):
        self.receiving_node1 = self.start_receiving_node(NODE_1, node_index=1, lightpush=lightpush, relay=relay, **kwargs)
        self.enr_uri = self.receiving_node1.get_enr_uri()

    @allure.step
    def setup_second_receiving_node(self, lightpush, relay, **kwargs):
        self.receiving_node2 = self.start_receiving_node(NODE_1, node_index=2, lightpush=lightpush, relay=relay, **kwargs)

    @allure.step
    def setup_additional_receiving_nodes(self, node_list=ADDITIONAL_NODES, **kwargs):
        if node_list:
            nodes = [node.strip() for node in node_list.split(",") if node]
        else:
            pytest.skip("ADDITIONAL_NODES/node_list is empty, cannot run test")
        for index, node in enumerate(nodes):
            self.start_receiving_node(node, node_index=index + 2, lightpush="true", relay="true", pubsub_topic=self.test_pubsub_topic, **kwargs)

    @allure.step
    def setup_first_lightpush_node(self, lightpush="true", relay="true", **kwargs):
        self.light_push_node1 = self.setup_lightpush_node(NODE_2, node_index=1, lightpush=lightpush, relay=relay, **kwargs)

    @allure.step
    def setup_second_lightpush_node(self, lightpush="true", relay="true", **kwargs):
        self.light_push_node2 = self.setup_lightpush_node(NODE_2, node_index=2, lightpush=lightpush, relay=relay, **kwargs)

    @allure.step
    def setup_additional_lightpush_nodes(self, node_list=ADDITIONAL_NODES, **kwargs):
        if node_list:
            nodes = [node.strip() for node in node_list.split(",") if node]
        else:
            pytest.skip("ADDITIONAL_NODES/node_list is empty, cannot run test")
        self.additional_lightpush_nodes = []
        for index, node in enumerate(nodes):
            node = self.setup_lightpush_node(node, node_index=index + 2, lightpush="true", relay="true", **kwargs)
            self.additional_lightpush_nodes.append(node)

    @allure.step
    def subscribe_to_pubsub_topics_via_relay(self, node=None, pubsub_topics=None):
        if pubsub_topics is None:
            pubsub_topics = [self.test_pubsub_topic]
        if not node:
            node = self.main_receiving_nodes
        if isinstance(node, list):
            for node in node:
                node.set_relay_subscriptions(pubsub_topics)
        else:
            node.set_relay_subscriptions(pubsub_topics)

    @allure.step
    def subscribe_to_pubsub_topics_via_filter(self, node, pubsub_topic=None, content_topic=None):
        if pubsub_topic is None:
            pubsub_topic = self.test_pubsub_topic
        if content_topic is None:
            content_topic = [self.test_content_topic]
        subscription = {"requestId": "1", "contentFilters": content_topic, "pubsubTopic": pubsub_topic}
        node.set_filter_subscriptions(subscription)

    @allure.step
    def check_light_pushed_message_reaches_receiving_peer(
        self, pubsub_topic=None, message=None, message_propagation_delay=None, sender=None, peer_list=None
    ):
        if pubsub_topic is None:
            pubsub_topic = self.test_pubsub_topic
        if not sender:
            sender = self.light_push_node1
        if not peer_list:
            peer_list = self.main_receiving_nodes + self.optional_nodes
        if message_propagation_delay is None:
            message_propagation_delay = self.default_message_propagation_delay
        payload = self.create_payload(pubsub_topic, message)
        logger.debug("Lightpushing message")
        sender.send_light_push_message(payload)
        delay(message_propagation_delay)
        for index, peer in enumerate(peer_list):
            logger.debug(f"Checking that peer NODE_{index + 1}:{peer.image} can find the lightpushed message")
            get_messages_response = peer.get_relay_messages(pubsub_topic)
            test_messages = [m for m in get_messages_response if m.get("contentTopic") == payload["message"]["contentTopic"]]
            assert test_messages, f"Peer NODE_{index + 1}:{peer.image} couldn't find any messages"
            assert len(test_messages) == 1, (
                f"Expected 1 test message but got {len(test_messages)} " f"(total messages in cache: {len(get_messages_response)})"
            )
            waku_message = WakuMessage(test_messages)
            waku_message.assert_received_message(payload["message"])

    @allure.step
    def create_payload(self, pubsub_topic=None, message=None, **kwargs):
        if message is None:
            message = self.create_message()
        if pubsub_topic is None:
            pubsub_topic = self.test_pubsub_topic
        payload = {"pubsubTopic": pubsub_topic, "message": message}
        payload.update(kwargs)
        return payload

    @allure.step
    @retry(stop=stop_after_delay(120), wait=wait_fixed(1), reraise=True)
    def subscribe_and_light_push_with_retry(self):
        self.subscribe_to_pubsub_topics_via_relay()
        self.light_push_node1.send_light_push_message(self.create_payload())
        get_messages_response = self.main_receiving_nodes[0].get_relay_messages(self.test_pubsub_topic)
        assert len(get_messages_response) >= 1, f"Expected al least 1 message but got {len(get_messages_response)}"
