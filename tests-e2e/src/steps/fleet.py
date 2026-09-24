import inspect
from concurrent.futures import ThreadPoolExecutor
from uuid import uuid4
import allure
import pytest
from src.env_vars import NODE_1
from src.libs.common import wait_until
from src.libs.custom_logger import get_custom_logger
from src.node.waku_node import WakuNode
from src.steps.common import StepsCommon
from src.test_data import FLEET_PRESET, FLEET_SHARDS

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
        # With Kademlia discovery on, the node serves only /health for minutes, until its service discovery has started.
        node.start(
            wait_for_node_sec=120,
            preset=FLEET_PRESET,
            enable_kad_discovery="false",
            shard=FLEET_SHARDS,
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
    def start_fleet_nodes(self, *starts):
        with ThreadPoolExecutor(max_workers=len(starts)) as pool:
            futures = [pool.submit(start, node_name) for start, node_name in starts]
            return [future.result() for future in futures]

    @allure.step
    def subscribe_through_fleet(self, receiver, timeout_duration=120):
        subscription = {"requestId": "1", "contentFilters": [self.test_content_topic]}
        wait_until(lambda: receiver.set_filter_subscriptions(subscription), timeout_duration, 1)

    @allure.step
    def light_push_through_fleet(self, sender, message, timeout_duration=120):
        def push():
            try:
                return sender.send_light_push_message({"message": message})
            except Exception as ex:
                # An earlier attempt published the message, so the resend is rejected as already seen.
                if "already-seen" in str(ex):
                    return True
                raise

        wait_until(push, timeout_duration, 1)

    @allure.step
    def relay_publish_through_fleet(self, sender, message, timeout_duration=120):
        wait_until(lambda: sender.get_relay_peers_on_shard(FLEET_SHARDS[0])["peers"], timeout_duration, 1)
        wait_until(lambda: sender.send_relay_auto_message(message), timeout_duration, 1)

    @allure.step
    def wait_for_fleet_store_messages(self, node, count, timeout_duration=60, time_between_retries=1):
        def stored_messages():
            messages = node.get_store_messages(include_data="true", content_topics=self.test_content_topic)["messages"]
            return messages if len(messages) >= count else None

        return wait_until(stored_messages, timeout_duration, time_between_retries, f"Expected {count} stored messages")
