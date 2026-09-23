from src.steps.sharding import StepsSharding


class TestRelayAutosharding(StepsSharding):
    def test_subscribe_and_publish_on_another_content_topic_from_another_shard(self):
        self.setup_main_nodes(cluster_id=self.auto_cluster, content_topic=self.test_content_topic, num_shards_in_network=self.num_shards_in_network)
        self.subscribe_main_relay_nodes(content_topics=["/toychat/2/huilong/proto"])
        self.wait_for_relay_peer(self.node1, self.node2, "/waku/2/rs/199/3")
        self.check_published_message_reaches_relay_peer(content_topic="/toychat/2/huilong/proto")
        self.check_published_message_reaches_relay_peer(content_topic=self.test_content_topic)
