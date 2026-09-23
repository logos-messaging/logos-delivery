import inspect
from src.libs.custom_logger import get_custom_logger
import pytest
import allure
from src.libs.common import wait_until
from src.node.waku_message import WakuMessage
from src.steps.relay import StepsRelay

logger = get_custom_logger(__name__)


class StepsSharding(StepsRelay):
    test_content_topic = "/myapp/1/latest/proto"
    test_payload = "Sharding works!!"
    auto_cluster = 199
    num_shards_in_network = 8

    @pytest.fixture(scope="function", autouse=True)
    def sharding_setup(self):
        logger.debug(f"Running fixture setup: {inspect.currentframe().f_code.co_name}")
        self.main_nodes = []
        self.optional_nodes = []

    @allure.step
    def subscribe_relay_node(self, node, content_topics, pubsub_topics):
        if content_topics:
            node.set_relay_auto_subscriptions(content_topics)
        elif pubsub_topics:
            node.set_relay_subscriptions(pubsub_topics)
        else:
            raise AttributeError("content_topics or pubsub_topics need to be passed")

    @allure.step
    def subscribe_main_relay_nodes(self, content_topics=None, pubsub_topics=None):
        for node in self.main_nodes:
            self.subscribe_relay_node(node, content_topics, pubsub_topics)

    @allure.step
    def relay_message(self, node, message, pubsub_topic=None):
        if pubsub_topic:
            node.send_relay_message(message, pubsub_topic)
        else:
            node.send_relay_auto_message(message)

    @allure.step
    def retrieve_relay_message(self, node, content_topic=None, pubsub_topic=None):
        if content_topic:
            return node.get_relay_auto_messages(content_topic)
        elif pubsub_topic:
            return node.get_relay_messages(pubsub_topic)
        else:
            raise AttributeError("content_topic or pubsub_topic needs to be passed")

    @allure.step
    def check_published_message_reaches_relay_peer(self, content_topic=None, pubsub_topic=None, sender=None, peer_list=None):
        message = self.create_message(contentTopic=content_topic) if content_topic else self.create_message()
        if not sender:
            sender = self.node1
        if not peer_list:
            peer_list = self.main_nodes + self.optional_nodes

        self.relay_message(sender, message, pubsub_topic)
        for index, peer in enumerate(peer_list):
            logger.debug(f"Checking that peer NODE_{index + 1}:{peer.image} can find the published message")
            get_messages_response = self.wait_for_relay_messages(peer, 1, content_topic=content_topic, pubsub_topic=pubsub_topic)
            assert len(get_messages_response) == 1, f"Expected 1 message but got {len(get_messages_response)}"
            waku_message = WakuMessage(get_messages_response)
            waku_message.assert_received_message(message)

    @allure.step
    def wait_for_relay_messages(self, node, count, pubsub_topic=None, content_topic=None, timeout_duration=20, time_between_retries=0.5):
        # Each GET returns only the messages received since the previous call, so they are collected across polls.
        if content_topic is None and pubsub_topic is None:
            pubsub_topic = self.test_pubsub_topic
        messages = []

        def all_messages_received():
            messages.extend(self.retrieve_relay_message(node, content_topic, pubsub_topic))
            return len(messages) >= count

        wait_until(all_messages_received, timeout_duration, time_between_retries, f"Expected {count} relay messages")
        return messages
