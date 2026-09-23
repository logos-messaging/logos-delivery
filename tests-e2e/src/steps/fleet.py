import inspect
from uuid import uuid4
import allure
import pytest
from src.env_vars import NODE_1
from src.libs.common import wait_until
from src.libs.custom_logger import get_custom_logger
from src.node.waku_node import WakuNode
from src.steps.common import StepsCommon
from src.test_data import LOGOS_DEV_CLUSTER_ID, LOGOS_DEV_PRESET, LOGOS_DEV_SHARDS, WAKU_LIGHTPUSH_CODEC

logger = get_custom_logger(__name__)


class StepsFleet(StepsCommon):
    test_payload = "Fleet round trip"

    @pytest.fixture(scope="function", autouse=True)
    def fleet_setup(self):
        logger.debug(f"Running fixture setup: {inspect.currentframe().f_code.co_name}")
        # The fleet carries other traffic; a content topic of the test's own keeps it out of every result.
        self.test_content_topic = f"/fleet-test/1/{uuid4()}/proto"

    @allure.step
    def start_fleet_node(self, node_name, relay):
        node = WakuNode(NODE_1, f"{node_name}_{self.test_id}")
        # A logos.dev node takes about a minute to start, and serves only /health until it has.
        node.start(
            wait_for_node_sec=120,
            preset=LOGOS_DEV_PRESET,
            cluster_id=LOGOS_DEV_CLUSTER_ID,
            shard=LOGOS_DEV_SHARDS,
            relay=relay,
            filter="false",
            lightpush="false",
        )
        return node

    @allure.step
    def start_fleet_relay_node(self, node_name):
        node = self.start_fleet_node(node_name, relay="true")
        node.set_relay_auto_subscriptions([self.test_content_topic])
        return node

    @allure.step
    def start_fleet_light_client(self, node_name):
        return self.start_fleet_node(node_name, relay="false")

    @allure.step
    def light_push_through_fleet(self, sender, message, timeout_duration=120):
        # Pushed once: a resent message is already seen by the relay and rejected.
        wait_until(
            lambda: any(WAKU_LIGHTPUSH_CODEC in peer["protocols"] for peer in sender.get_peers()),
            timeout_duration,
            1,
            "No fleet lightpush peer",
        )
        sender.send_light_push_message({"message": message})

    @allure.step
    def relay_publish_through_fleet(self, sender, message, timeout_duration=120):
        wait_until(lambda: sender.send_relay_auto_message(message), timeout_duration, 1, "The relay node had no fleet peer to publish to")

    @allure.step
    def wait_for_fleet_store_messages(self, node, count, timeout_duration=60, time_between_retries=1):
        def stored_messages():
            messages = node.get_store_messages(include_data="true", content_topics=self.test_content_topic)["messages"]
            return messages if len(messages) >= count else None

        return wait_until(stored_messages, timeout_duration, time_between_retries, f"Expected {count} stored messages")
