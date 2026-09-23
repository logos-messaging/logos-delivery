import base64
import hashlib
import inspect
from time import time_ns
import pytest
from tenacity import retry, stop_after_delay, wait_fixed
from src.libs.common import delay, to_base64, wait_until
from src.libs.custom_logger import get_custom_logger
from src.node.waku_node import peer_info2id

logger = get_custom_logger(__name__)


class StepsCommon:
    @pytest.fixture(scope="function", autouse=True)
    def common_setup(self):
        logger.debug(f"Running fixture setup: {inspect.currentframe().f_code.co_name}")
        if not hasattr(self, "test_payload"):
            self.test_payload = "Default Payload"
        if not hasattr(self, "test_content_topic"):
            self.test_content_topic = "/test/1/default/proto"

    @retry(stop=stop_after_delay(20), wait=wait_fixed(0.5), reraise=True)
    def add_node_peer(self, node, multiaddr_list, shards=[0, 1, 2, 3, 4, 5, 6, 7, 8]):
        if node.is_nwaku():
            for multiaddr in multiaddr_list:
                node.add_peers([multiaddr])

    @retry(stop=stop_after_delay(70), wait=wait_fixed(1), reraise=True)
    def wait_for_autoconnection(self, node_list, hard_wait=None):
        for node in node_list:
            get_peers = node.get_peers()
            assert len(get_peers) >= 1
        if hard_wait:
            delay(hard_wait)

    def wait_for_relay_peer(self, node, peer, pubsub_topic, timeout_duration=30, time_between_retries=1):
        shard_id = pubsub_topic.split("/")[-1]
        peer_id = peer.get_id()

        def peer_subscribed():
            return peer_id in {peer_info2id(p) for p in node.get_relay_peers_on_shard(shard_id)["peers"]}

        wait_until(peer_subscribed, timeout_duration, time_between_retries, f"Expected {peer_id} among the relay peers on shard {shard_id}")

    def wait_for_mesh_peer(self, node, peer, pubsub_topic, timeout_duration=30, time_between_retries=1):
        shard_id = pubsub_topic.split("/")[-1]
        peer_id = peer.get_id()

        def peer_in_mesh():
            return peer_id in {peer_info2id(p) for p in node.get_mesh_peers_on_shard(shard_id)["peers"]}

        wait_until(peer_in_mesh, timeout_duration, time_between_retries, f"Expected {peer_id} among the mesh peers on shard {shard_id}")

    def create_message(self, **kwargs):
        ts_ns = time_ns()
        ts_ns = int(f"{ts_ns:019d}")
        message = {"payload": to_base64(self.test_payload), "contentTopic": self.test_content_topic, "timestamp": ts_ns}
        message.update(kwargs)
        return message

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
