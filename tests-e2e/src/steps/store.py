import inspect

from src.libs.custom_logger import get_custom_logger
import pytest
from src.libs.common import delay
from src.node.store_response import StoreResponse
from src.node.waku_message import WakuMessage
from src.env_vars import (
    NODE_1,
    NODE_2,
)
from src.node.waku_node import WakuNode
from src.steps.common import StepsCommon
from src.test_data import VALID_PUBSUB_TOPICS
from tenacity import retry, stop_after_delay, wait_fixed

logger = get_custom_logger(__name__)


class StepsStore(StepsCommon):
    test_content_topic = "/myapp/1/latest/proto"
    test_pubsub_topic = VALID_PUBSUB_TOPICS[0]
    test_payload = "Store works!!"

    @pytest.fixture(scope="function", autouse=True)
    def store_setup(self):
        logger.debug(f"Running fixture setup: {inspect.currentframe().f_code.co_name}")
        self.main_publishing_nodes = []
        self.store_nodes = []
        self.optional_nodes = []
        self.multiaddr_list = []

    @pytest.fixture(scope="function", autouse=False)
    def node_setup(self, store_setup):
        logger.debug(f"Running fixture setup: {inspect.currentframe().f_code.co_name}")
        self.setup_first_publishing_node(store="true", relay="true")
        self.setup_first_store_node(store="true", relay="true")
        self.subscribe_to_pubsub_topics_via_relay(node=self.main_publishing_nodes)

    def start_publishing_node(self, image, node_index, **kwargs):
        node = WakuNode(image, f"publishing_node{node_index}_{self.test_id}")
        node.start(**kwargs)
        if kwargs["relay"] == "true":
            self.main_publishing_nodes.extend([node])
        if kwargs["store"] == "true":
            self.store_nodes.extend([node])
        self.add_node_peer(node, self.multiaddr_list)
        self.multiaddr_list.extend([node.get_multiaddr_with_id()])
        return node

    def setup_store_node(self, image, node_index, **kwargs):
        node = WakuNode(image, f"store_node{node_index}_{self.test_id}")
        node.start(discv5_bootstrap_node=self.enr_uri, storenode=self.multiaddr_list[0], **kwargs)
        if kwargs["relay"] == "true":
            self.main_publishing_nodes.extend([node])
        self.store_nodes.extend([node])
        self.add_node_peer(node, self.multiaddr_list)
        return node

    def setup_first_publishing_node(self, store="true", relay="true", **kwargs):
        self.publishing_node1 = self.start_publishing_node(NODE_1, node_index=1, store=store, relay=relay, **kwargs)
        self.enr_uri = self.publishing_node1.get_enr_uri()

    def setup_second_publishing_node(self, store, relay, **kwargs):
        self.publishing_node2 = self.start_publishing_node(NODE_1, node_index=2, store=store, relay=relay, **kwargs)

    def setup_first_store_node(self, store="true", relay="true", **kwargs):
        self.store_node1 = self.setup_store_node(NODE_2, node_index=1, store=store, relay=relay, **kwargs)

    def subscribe_to_pubsub_topics_via_relay(self, node=None, pubsub_topics=None):
        if pubsub_topics is None:
            pubsub_topics = [self.test_pubsub_topic]
        if not node:
            node = self.main_publishing_nodes
        if isinstance(node, list):
            for node in node:
                node.set_relay_subscriptions(pubsub_topics)
        else:
            node.set_relay_subscriptions(pubsub_topics)

    def subscribe_to_pubsub_topics_via_filter(self, node, pubsub_topic=None, content_topic=None):
        if pubsub_topic is None:
            pubsub_topic = self.test_pubsub_topic
        if content_topic is None:
            content_topic = [self.test_content_topic]
        subscription = {"requestId": "1", "contentFilters": content_topic, "pubsubTopic": pubsub_topic}
        node.set_filter_subscriptions(subscription)

    def publish_message(self, via="relay", pubsub_topic=None, message=None, message_propagation_delay=0.2, sender=None):
        self.message = self.create_message() if message is None else message
        if pubsub_topic is None:
            pubsub_topic = self.test_pubsub_topic
        if not sender:
            sender = self.publishing_node1
        if via == "relay":
            logger.debug("Relaying message")
            sender.send_relay_message(self.message, pubsub_topic)
        elif via == "lightpush":
            payload = self.create_payload(pubsub_topic, self.message)
            sender.send_light_push_message(payload)
        delay(message_propagation_delay)
        return self.message

    def get_messages_from_store(
        self,
        node=None,
        peer_addr=None,
        include_data=None,
        pubsub_topic=None,
        content_topics=None,
        start_time=None,
        end_time=None,
        hashes=None,
        cursor=None,
        page_size=None,
        ascending="true",
        store_v="v3",
        **kwargs,
    ):
        if pubsub_topic is None:
            pubsub_topic = self.test_pubsub_topic
        store_response = node.get_store_messages(
            peer_addr=peer_addr,
            include_data=include_data,
            pubsub_topic=pubsub_topic,
            content_topics=content_topics,
            start_time=start_time,
            end_time=end_time,
            hashes=hashes,
            cursor=cursor,
            page_size=page_size,
            ascending=ascending,
            store_v=store_v,
            **kwargs,
        )
        store_response = StoreResponse(store_response, node)
        assert store_response.request_id is not None, "Request id is missing"
        assert store_response.status_code, "Status code is missing"
        assert store_response.status_desc, "Status desc is missing"
        return store_response

    def check_published_message_is_stored(
        self,
        store_node=None,
        peer_addr=None,
        include_data=None,
        pubsub_topic=None,
        content_topics=None,
        start_time=None,
        end_time=None,
        hashes=None,
        cursor=None,
        page_size=None,
        ascending=None,
        store_v="v3",
        messages_to_check=None,
        **kwargs,
    ):
        if pubsub_topic is None:
            pubsub_topic = self.test_pubsub_topic
        if messages_to_check is None:
            messages_to_check = [self.message]
        if store_node is None:
            store_node = self.store_nodes
        elif not isinstance(store_node, list):
            store_node = [store_node]
        for node in store_node:
            logger.debug(f"Checking that peer {node.image} can find the stored messages")
            self.store_response = self.get_messages_from_store(
                node=node,
                peer_addr=peer_addr,
                include_data=include_data,
                pubsub_topic=pubsub_topic,
                content_topics=content_topics,
                start_time=start_time,
                end_time=end_time,
                hashes=hashes,
                cursor=cursor,
                page_size=page_size,
                ascending=ascending,
                store_v=store_v,
                **kwargs,
            )

            logger.debug(f"messages length is {len(self.store_response.messages)}")
            assert self.store_response.messages, f"Peer {node.image} couldn't find any messages. Actual response: {self.store_response.resp_json}"
            assert len(self.store_response.messages) >= len(
                messages_to_check
            ), f"Expected at least {len(messages_to_check)} messages but got {len(self.store_response.messages)}"

            # Determine the range of indices for message comparison
            if len(messages_to_check) == 1:
                indices = [-1]  # Use the last message in the store response for a single message
            else:
                indices = range(len(messages_to_check))  # Use corresponding indices for multiple messages

            # Iterate through messages_to_check and their respective indices
            for idx, message_to_check in zip(indices, messages_to_check):
                if store_v == "v1":
                    waku_message = WakuMessage([self.store_response.messages[idx]])
                    waku_message.assert_received_message(message_to_check)
                else:
                    hash_type = "hex" if node.is_nwaku() else "base64"
                    expected_hash = self.compute_message_hash(pubsub_topic, message_to_check, hash_type=hash_type)
                    actual_hash = self.store_response.message_hash(idx)
                    assert (
                        expected_hash == actual_hash
                    ), f"Message hash at index {idx} returned by store doesn't match the computed message hash {expected_hash}. Actual hash: {actual_hash}"

    def wait_for_published_message_is_stored(self, timeout_duration=30, time_between_retries=1, **kwargs):
        @retry(stop=stop_after_delay(timeout_duration), wait=wait_fixed(time_between_retries), reraise=True)
        def check_until_stored():
            self.check_published_message_is_stored(**kwargs)

        check_until_stored()

    def check_sent_message_is_stored(
        self,
        expected_hashes,
        store_node=None,
        peer_addr=None,
        include_data=None,
        pubsub_topic=None,
        content_topics=None,
        start_time=None,
        end_time=None,
        hashes=None,
        cursor=None,
        page_size=None,
        ascending=None,
        store_v="v3",
        **kwargs,
    ):
        """Verify that messages with the given hashes are present in the store."""
        if pubsub_topic is None:
            pubsub_topic = self.test_pubsub_topic
        if isinstance(expected_hashes, str):
            expected_hashes = [expected_hashes]
        if store_node is None:
            store_node = self.store_nodes
        elif not isinstance(store_node, list):
            store_node = [store_node]

        for node in store_node:
            logger.debug(f"Checking that peer {node.image} can find the stored messages by hash")
            self.store_response = self.get_messages_from_store(
                node=node,
                peer_addr=peer_addr,
                include_data=include_data,
                pubsub_topic=pubsub_topic,
                content_topics=content_topics,
                start_time=start_time,
                end_time=end_time,
                hashes=hashes,
                cursor=cursor,
                page_size=page_size,
                ascending=ascending,
                store_v=store_v,
                **kwargs,
            )

            logger.debug(f"messages length is {len(self.store_response.messages)}")
            assert self.store_response.messages, f"Peer {node.image} couldn't find any messages. " f"Actual response: {self.store_response.resp_json}"
            assert len(self.store_response.messages) >= len(expected_hashes), (
                f"Expected at least {len(expected_hashes)} messages " f"but got {len(self.store_response.messages)}"
            )

            actual_hashes = [self.store_response.message_hash(i) for i in range(len(self.store_response.messages))]
            for expected_hash in expected_hashes:
                assert expected_hash in actual_hashes, f"Expected hash {expected_hash} not found in store. " f"Actual hashes: {actual_hashes}"

    def create_payload(self, pubsub_topic=None, message=None, **kwargs):
        if message is None:
            message = self.create_message()
        if pubsub_topic is None:
            pubsub_topic = self.test_pubsub_topic
        payload = {"pubsubTopic": pubsub_topic, "message": message}
        payload.update(kwargs)
        return payload
