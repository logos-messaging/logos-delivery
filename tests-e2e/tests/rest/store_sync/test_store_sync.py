import pytest
from src.env_vars import NODE_1
from src.libs.common import delay
from src.node.waku_node import WakuNode
from src.steps.store import StepsStore


class TestStoreSync(StepsStore):
    @pytest.fixture(scope="function", autouse=True)
    def nodes(self):
        self.node1 = WakuNode(NODE_1, f"node1_{self.test_id}")
        self.node2 = WakuNode(NODE_1, f"node2_{self.test_id}")

    def publish_messages(self, count):
        return [self.publish_message(sender=self.node1, via="relay", message_propagation_delay=0) for _ in range(count)]

    def test_store_sync_range_with_zero_jitter(self):
        sync_range = 20
        publish_count = 3

        self.node1.start(store="true", store_sync="true", relay="true", dns_discovery="false")
        self.node1.set_relay_subscriptions([self.test_pubsub_topic])
        self.publish_messages(publish_count)

        # Nothing observable marks the moment these messages leave the range.
        delay(sync_range)
        # node2 has no relay, so every message it holds came through store sync.
        self.node2.start(
            store="true",
            store_sync="true",
            store_sync_interval=2,
            store_sync_range=sync_range,
            store_sync_relay_jitter=0,
            relay="false",
            dns_discovery="false",
            discv5_bootstrap_node=self.node1.get_enr_uri(),
        )
        self.add_node_peer(self.node2, [self.node1.get_multiaddr_with_id()])

        in_range_messages = self.publish_messages(publish_count)
        self.wait_for_published_message_is_stored(store_node=self.node2, page_size=100, ascending="true", messages_to_check=in_range_messages)
        assert len(self.store_response.messages) == publish_count

        next_session_messages = self.publish_messages(publish_count)
        self.wait_for_published_message_is_stored(
            store_node=self.node2, page_size=100, ascending="true", messages_to_check=in_range_messages + next_session_messages
        )
        assert len(self.store_response.messages) == 2 * publish_count
