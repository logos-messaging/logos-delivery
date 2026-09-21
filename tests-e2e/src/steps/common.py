import base64
import hashlib
import inspect
from time import time
from time import time_ns
import allure
import pytest
from datetime import timedelta, datetime
from tenacity import retry, stop_after_delay, wait_fixed
from src.libs.common import delay, to_base64, wait_until
from src.libs.custom_logger import get_custom_logger

logger = get_custom_logger(__name__)


class StepsCommon:
    @pytest.fixture(scope="function", autouse=True)
    def common_setup(self):
        logger.debug(f"Running fixture setup: {inspect.currentframe().f_code.co_name}")
        if not hasattr(self, "test_payload"):
            self.test_payload = "Default Payload"
        if not hasattr(self, "test_content_topic"):
            self.test_content_topic = "/test/1/default/proto"

    @allure.step
    @retry(stop=stop_after_delay(20), wait=wait_fixed(0.5), reraise=True)
    def add_node_peer(self, node, multiaddr_list, shards=[0, 1, 2, 3, 4, 5, 6, 7, 8]):
        if node.is_nwaku():
            for multiaddr in multiaddr_list:
                node.add_peers([multiaddr])

    @allure.step
    @retry(stop=stop_after_delay(70), wait=wait_fixed(1), reraise=True)
    def wait_for_autoconnection(self, node_list, hard_wait=None):
        for node in node_list:
            get_peers = node.get_peers()
            assert len(get_peers) >= 1
        if hard_wait:
            delay(hard_wait)

    @allure.step
    def wait_for_relay_peer(self, node, peer, pubsub_topic, timeout_duration=30, time_between_retries=1):
        shard_id = pubsub_topic.split("/")[-1]
        peer_id = peer.get_id()

        def peer_subscribed():
            return peer_id in {p["multiaddr"].rpartition("/p2p/")[2] for p in node.get_relay_peers_on_shard(shard_id)["peers"]}

        wait_until(peer_subscribed, timeout_duration, time_between_retries, f"Expected {peer_id} among the relay peers on shard {shard_id}")

    @allure.step
    def create_message(self, **kwargs):
        ts_ns = time_ns()
        ts_ns = int(f"{ts_ns:019d}")
        message = {"payload": to_base64(self.test_payload), "contentTopic": self.test_content_topic, "timestamp": ts_ns}
        message.update(kwargs)
        return message

    @allure.step
    def compute_message_hash(self, pubsub_topic, msg, hash_type="hex"):
        ctx = hashlib.sha256()
        ctx.update(pubsub_topic.encode("utf-8"))
        ctx.update(base64.b64decode(msg["payload"]))
        ctx.update(msg["contentTopic"].encode("utf-8"))
        if "meta" in msg:
            ctx.update(base64.b64decode(msg["meta"]))
        ctx.update(int(msg["timestamp"]).to_bytes(8, byteorder="big"))
        hash_bytes = ctx.digest()
        if hash_type == "hex":
            return "0x" + hash_bytes.hex()
        else:
            return base64.b64encode(hash_bytes).decode("utf-8")

    def get_time_list_pass(self):
        ts_pass = [
            {"description": "3 sec Past", "value": int((datetime.now() - timedelta(seconds=3)).timestamp() * 1e9)},
            {"description": "1 sec Past", "value": int((datetime.now() - timedelta(seconds=1)).timestamp() * 1e9)},
            {"description": "0.1 sec Past", "value": int((datetime.now() - timedelta(seconds=0.1)).timestamp() * 1e9)},
            {"description": "0.1 sec Future", "value": int((datetime.now() + timedelta(seconds=0.1)).timestamp() * 1e9)},
            {"description": "2 sec Future", "value": int((datetime.now() + timedelta(seconds=2)).timestamp() * 1e9)},
            {"description": "10 sec Future", "value": int((datetime.now() + timedelta(seconds=10)).timestamp() * 1e9)},
        ]
        return ts_pass

    def get_time_list_fail(self):
        ts_fail = [
            {"description": "20 sec Past", "value": int((datetime.now() - timedelta(seconds=20)).timestamp() * 1e9)},
            {"description": "40 sec Future", "value": int((datetime.now() + timedelta(seconds=40)).timestamp() * 1e9)},
        ]
        return ts_fail
