import inspect
from uuid import uuid4
from src.libs.custom_logger import get_custom_logger
from time import time
import pytest
import allure
from src.libs.common import to_base64, delay
from src.node.waku_message import WakuMessage
from src.env_vars import NODE_1, NODE_2, ADDITIONAL_NODES
from src.node.waku_node import WakuNode
from tenacity import retry, stop_after_delay, wait_fixed
from src.steps.common import StepsCommon
from src.test_data import VALID_PUBSUB_TOPICS

logger = get_custom_logger(__name__)


class StepsFilter(StepsCommon):
    test_pubsub_topic = VALID_PUBSUB_TOPICS[1]
    second_pubsub_topic = VALID_PUBSUB_TOPICS[2]
    another_cluster_pubsub_topic = "/waku/2/rs/199/2"
    test_content_topic = "/test/1/waku-filter/proto"
    second_content_topic = "/test/2/waku-filter/proto"
    test_payload = "Filter works!!"

    @pytest.fixture(scope="function", autouse=True)
    def filter_setup(self):
        logger.debug(f"Running fixture setup: {inspect.currentframe().f_code.co_name}")
        self.main_nodes = []
        self.optional_nodes = []

    @pytest.fixture(scope="function")
    def setup_main_relay_node(self):
        logger.debug(f"Running fixture setup: {inspect.currentframe().f_code.co_name}")
        self.relay_node_start(NODE_1)

    @pytest.fixture(scope="function")
    def setup_main_filter_node(self):
        logger.debug(f"Running fixture setup: {inspect.currentframe().f_code.co_name}")
        self.node2 = WakuNode(NODE_2, f"node2_{self.test_id}")
        self.node2.start(relay="false", discv5_bootstrap_node=self.enr_uri, filternode=self.multiaddr_with_id)
        self.add_node_peer(self.node2, [self.multiaddr_with_id])
        self.main_nodes.append(self.node2)

    @pytest.fixture(scope="function")
    def subscribe_main_nodes(self):
        logger.debug(f"Running fixture setup: {inspect.currentframe().f_code.co_name}")
        self.wait_for_subscriptions_on_main_nodes([self.test_content_topic])

    @pytest.fixture(scope="function")
    @retry(stop=stop_after_delay(20), wait=wait_fixed(1), reraise=True)
    def filter_warm_up(self):
        try:
            self.ping_filter_subscriptions("1")
        except Exception as ex:
            if "peer has no subscriptions" in str(ex):
                logger.info("WARM UP successful!!")
            else:
                raise TimeoutError(f"WARM UP FAILED WITH: {ex}")

    def relay_node_start(self, node):
        self.node1 = WakuNode(node, f"node1_{self.test_id}")
        start_args = {"relay": "true", "filter": "true"}
        self.node1.start(**start_args)
        self.enr_uri = self.node1.get_enr_uri()
        self.multiaddr_with_id = self.node1.get_multiaddr_with_id()
        return self.node1

    def setup_optional_filter_nodes(self, node_list=ADDITIONAL_NODES):
        if node_list:
            nodes = [node.strip() for node in node_list.split(",") if node]
        else:
            pytest.skip("ADDITIONAL_NODES/node_list is empty, cannot run test")
        for index, node in enumerate(nodes):
            node = WakuNode(node, f"node{index + 3}_{self.test_id}")
            node.start(relay="false", discv5_bootstrap_node=self.enr_uri, filternode=self.multiaddr_with_id)
            self.add_node_peer(node, [self.multiaddr_with_id])
            self.optional_nodes.append(node)

    @allure.step
    def check_published_message_reaches_filter_peer(
        self, message=None, pubsub_topic=None, message_propagation_delay=0.1, sender=None, peer_list=None
    ):
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
            logger.debug(f"Checking that peer NODE_{index + 2}:{peer.image} can find the published message")
            get_messages_response = self.get_filter_messages(message["contentTopic"], pubsub_topic=pubsub_topic, node=peer)
            # get_filter_messages already scopes to the requested content topic
            # additional filter guards against any residual or fleet messages that may
            # have been queued under the same topic before this call
            test_messages = [m for m in get_messages_response if m.get("contentTopic") == message["contentTopic"]]
            assert test_messages, f"Peer NODE_{index + 2}:{peer.image} couldn't find any messages"
            assert len(test_messages) == 1, (
                f"Expected 1 test message but got {len(test_messages)} " f"(total messages returned: {len(get_messages_response)})"
            )
            waku_message = WakuMessage(test_messages)
            waku_message.assert_received_message(message)

    @allure.step
    def check_publish_without_filter_subscription(self, message=None, pubsub_topic=None, peer_list=None):
        try:
            self.check_published_message_reaches_filter_peer(message=message, pubsub_topic=pubsub_topic, peer_list=peer_list)
            raise AssertionError("Publish with no subscription worked!!!")
        except Exception as ex:
            assert "Bad Request" in str(ex) or "Not Found" in str(ex) or "couldn't find any messages" in str(ex)

    @allure.step
    def wait_for_subscriptions_on_main_nodes(self, content_topic_list, pubsub_topic=None):
        if pubsub_topic is None:
            pubsub_topic = self.test_pubsub_topic
        self.node1.set_relay_subscriptions([pubsub_topic])
        request_id = str(uuid4())
        filter_sub_response = self.create_filter_subscription_with_retry(
            {"requestId": request_id, "contentFilters": content_topic_list, "pubsubTopic": pubsub_topic}
        )
        assert filter_sub_response["requestId"] == request_id
        assert filter_sub_response["statusDesc"] in ["OK"]

    @allure.step
    def subscribe_optional_filter_nodes(self, content_topic_list, pubsub_topic=None):
        if pubsub_topic is None:
            pubsub_topic = self.test_pubsub_topic
        for node in self.optional_nodes:
            request_id = str(uuid4())
            self.create_filter_subscription_with_retry(
                {"requestId": request_id, "contentFilters": content_topic_list, "pubsubTopic": pubsub_topic}, node=node
            )

    @retry(stop=stop_after_delay(60), wait=wait_fixed(1), reraise=True)
    @allure.step
    def create_filter_subscription_with_retry(self, subscription, node=None):
        return self.create_filter_subscription(subscription, node)

    @allure.step
    def create_filter_subscription(self, subscription, node=None):
        if node is None:
            node = self.node2
        return node.set_filter_subscriptions(subscription)

    @allure.step
    def update_filter_subscription(self, subscription, node=None):
        if node is None:
            node = self.node2
        return node.update_filter_subscriptions(subscription)

    @allure.step
    def delete_filter_subscription(self, subscription, status=None, node=None):
        if node is None:
            node = self.node2
        delete_sub_response = node.delete_filter_subscriptions(subscription)
        assert delete_sub_response["requestId"] == subscription["requestId"]
        if status is None:
            assert delete_sub_response["statusDesc"] in ["OK"]
        else:
            assert status in delete_sub_response["statusDesc"]

    @allure.step
    def delete_all_filter_subscriptions(self, request_id, node=None):
        if node is None:
            node = self.node2
        delete_sub_response = node.delete_all_filter_subscriptions(request_id)
        assert delete_sub_response["requestId"] == request_id["requestId"]
        assert delete_sub_response["statusDesc"] in ["OK"]

    @allure.step
    def ping_filter_subscriptions(self, request_id, node=None):
        if node is None:
            node = self.node2
        ping_sub_response = node.ping_filter_subscriptions(request_id)
        assert ping_sub_response["requestId"] == request_id
        assert ping_sub_response["statusDesc"] in ["OK"]

    def ping_without_filter_subscription(self, node=None):
        try:
            self.ping_filter_subscriptions(str(uuid4()), node=node)
            raise AssertionError("Ping without any subscription worked")
        except Exception as ex:
            assert "peer has no subscription" in str(ex) or "ping request failed" in str(ex)

    @allure.step
    def add_new_relay_subscription(self, pubsub_topics, node=None):
        if node is None:
            node = self.node1
        self.node1.set_relay_subscriptions(pubsub_topics)

    @allure.step
    def get_filter_messages(self, content_topic, pubsub_topic=None, node=None):
        if node is None:
            node = self.node2
        if node.is_nwaku():
            return node.get_filter_messages(content_topic)
        else:
            raise NotImplementedError("Not implemented for this node type")
