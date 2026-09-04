import inspect
from src.libs.custom_logger import get_custom_logger
from time import time
import pytest
import allure
from src.libs.common import to_base64, delay
from src.node.waku_message import WakuMessage
from src.env_vars import (
    NODE_1,
    NODE_2,
    ADDITIONAL_NODES,
)
from src.node.waku_node import WakuNode
from tenacity import retry, stop_after_delay, wait_fixed
from src.steps.common import StepsCommon
from src.test_data import VALID_PUBSUB_TOPICS

logger = get_custom_logger(__name__)


class StepsRelay(StepsCommon):
    test_pubsub_topic = VALID_PUBSUB_TOPICS[1]
    test_content_topic = "/test/1/waku-relay/proto"
    test_payload = "Relay works!!"

    @pytest.fixture(scope="function", autouse=True)
    def relay_setup(self):
        logger.debug(f"Running fixture setup: {inspect.currentframe().f_code.co_name}")
        self.main_nodes = []
        self.optional_nodes = []

    @pytest.fixture(scope="function")
    def setup_main_relay_nodes(self, request):
        logger.debug(f"Running fixture setup: {inspect.currentframe().f_code.co_name}")
        self.node1 = WakuNode(NODE_1, f"node1_{request.cls.test_id}")
        self.node1.start(relay="true")
        self.enr_uri = self.node1.get_enr_uri()
        self.multiaddr_with_id = self.node1.get_multiaddr_with_id()
        self.node2 = WakuNode(NODE_2, f"node2_{request.cls.test_id}")
        self.node2.start(relay="true", discv5_bootstrap_node=self.enr_uri)
        self.add_node_peer(self.node2, [self.multiaddr_with_id])
        self.main_nodes.extend([self.node1, self.node2])

    @pytest.fixture(scope="function")
    def setup_optional_relay_nodes(self, request):
        logger.debug(f"Running fixture setup: {inspect.currentframe().f_code.co_name}")
        if ADDITIONAL_NODES:
            nodes = [node.strip() for node in ADDITIONAL_NODES.split(",")]
        else:
            pytest.skip("ADDITIONAL_NODES is empty, cannot run test")
        for index, node in enumerate(nodes):
            node = WakuNode(node, f"node{index + 3}_{request.cls.test_id}")
            node.start(relay="true", discv5_bootstrap_node=self.enr_uri)
            self.add_node_peer(node, [self.multiaddr_with_id])
            self.optional_nodes.append(node)

    @pytest.fixture(scope="function")
    def subscribe_main_relay_nodes(self):
        logger.debug(f"Running fixture setup: {inspect.currentframe().f_code.co_name}")
        self.ensure_relay_subscriptions_on_nodes(self.main_nodes, [self.test_pubsub_topic])

    @pytest.fixture(scope="function")
    def subscribe_optional_relay_nodes(self):
        logger.debug(f"Running fixture setup: {inspect.currentframe().f_code.co_name}")
        self.ensure_relay_subscriptions_on_nodes(self.optional_nodes, [self.test_pubsub_topic])

    @pytest.fixture(scope="function")
    def relay_warm_up(self):
        try:
            self.wait_for_published_message_to_reach_relay_peer()
            logger.info("WARM UP successful!!")
        except Exception as ex:
            raise TimeoutError(f"WARM UP FAILED WITH: {ex}")

    # Refactor candidate
    @allure.step
    def setup_first_relay_node(self, **kwargs):
        self.node1 = WakuNode(NODE_1, f"node1_{self.test_id}")
        self.node1.start(relay="true", **kwargs)
        self.enr_uri = self.node1.get_enr_uri()
        self.multiaddr_with_id = self.node1.get_multiaddr_with_id()
        self.main_nodes.extend([self.node1])

    # Refactor candidate
    @allure.step
    def setup_second_relay_node(self, **kwargs):
        self.node2 = WakuNode(NODE_2, f"node2_{self.test_id}")
        self.node2.start(
            relay="true",
            discv5_bootstrap_node=self.enr_uri,
            **kwargs,
        )
        self.add_node_peer(self.node2, [self.multiaddr_with_id])
        self.main_nodes.extend([self.node2])

    @allure.step
    def setup_third_relay_node(self, **kwargs):
        self.node3 = WakuNode(NODE_1, f"node3_{self.test_id}")
        self.node3.start(
            relay="true",
            discv5_bootstrap_node=self.enr_uri,
            **kwargs,
        )
        self.add_node_peer(self.node3, [self.multiaddr_with_id])
        self.optional_nodes.extend([self.node3])

    # this method should be used only for the tests that use the relay_warm_up fixture
    # otherwise use wait_for_published_message_to_reach_relay_peer
    @allure.step
    def check_published_message_reaches_relay_peer(self, message=None, pubsub_topic=None, message_propagation_delay=0.1, sender=None, peer_list=None):
        if message is None:
            message = self.create_message()
        if pubsub_topic is None:
            pubsub_topic = self.test_pubsub_topic
        if not sender:
            sender = self.node1
        if not peer_list:
            peer_list = self.main_nodes + self.optional_nodes

        sender.send_relay_message(message, pubsub_topic)
        delay(message_propagation_delay)
        for index, peer in enumerate(peer_list):
            logger.debug(f"Checking that peer NODE_{index + 1}:{peer.image} can find the published message")
            get_messages_response = peer.get_relay_messages(pubsub_topic)
            # In fleet mode the relay cache may contain background messages from other
            # fleet participants.  Filter to only the message whose contentTopic matches
            # what the test sent so that fleet noise does not break the count assertion.
            test_messages = [m for m in get_messages_response if m.get("contentTopic") == message["contentTopic"]]
            assert test_messages, f"Peer NODE_{index + 1}:{peer.image} couldn't find any messages"
            assert len(test_messages) == 1, (
                f"Expected 1 test message but got {len(test_messages)} " f"(total messages in cache: {len(get_messages_response)})"
            )
            waku_message = WakuMessage(test_messages)
            waku_message.assert_received_message(message)

    @allure.step
    def check_publish_without_relay_subscription(self, pubsub_topic):
        try:
            self.node1.send_relay_message(self.create_message(), pubsub_topic)
            raise AssertionError("Publish with no subscription worked!!!")
        except Exception as ex:
            assert "Bad Request" in str(ex) or "Internal Server Error" in str(ex)

    # we need much bigger timeout in CI because we run tests in parallel there and the machine itself is slower
    @allure.step
    def wait_for_published_message_to_reach_relay_peer(
        self, timeout_duration=120, time_between_retries=1, pubsub_topic=None, sender=None, peer_list=None
    ):
        @retry(stop=stop_after_delay(timeout_duration), wait=wait_fixed(time_between_retries), reraise=True)
        def publish_and_check_relay_peer():
            message = {"payload": to_base64(self.test_payload), "contentTopic": self.test_content_topic, "timestamp": int(time() * 1e9)}
            self.check_published_message_reaches_relay_peer(message, pubsub_topic=pubsub_topic, sender=sender, peer_list=peer_list)

        publish_and_check_relay_peer()

    @allure.step
    def ensure_relay_subscriptions_on_nodes(self, node_list, pubsub_topic_list):
        for node in node_list:
            node.set_relay_subscriptions(pubsub_topic_list)

    @allure.step
    def delete_relay_subscriptions_on_nodes(self, node_list, pubsub_topic_list):
        for node in node_list:
            node.delete_relay_subscriptions(pubsub_topic_list)

    @allure.step
    @retry(stop=stop_after_delay(120), wait=wait_fixed(1), reraise=True)
    def subscribe_and_publish_with_retry(self, node_list, pubsub_topic_list):
        self.ensure_relay_subscriptions_on_nodes(node_list, pubsub_topic_list)
        self.check_published_message_reaches_relay_peer()

    @allure.step
    def setup_main_nodes(self, **kwargs):
        self.node1 = WakuNode(NODE_1, f"node1_{self.test_id}")
        self.node1.start(relay="true", **kwargs)
        self.enr_uri = self.node1.get_enr_uri()
        self.multiaddr_with_id = self.node1.get_multiaddr_with_id()
        self.node2 = WakuNode(NODE_2, f"node2_{self.test_id}")
        self.node2.start(relay="true", discv5_bootstrap_node=self.enr_uri, **kwargs)
        self.add_node_peer(self.node2, [self.multiaddr_with_id])
        self.main_nodes.extend([self.node1, self.node2])

    @allure.step
    def setup_optional_nodes(self, **kwargs):
        if ADDITIONAL_NODES:
            nodes = [node.strip() for node in ADDITIONAL_NODES.split(",")]
        else:
            pytest.skip("ADDITIONAL_NODES is empty, cannot run test")
        for index, node in enumerate(nodes):
            node = WakuNode(node, f"node{index + 3}_{self.test_id}")
            node.start(relay="true", discv5_bootstrap_node=self.enr_uri, **kwargs)
            self.add_node_peer(node, [self.multiaddr_with_id])
            self.optional_nodes.append(node)
