import pytest
from src.steps.store import StepsStore


class TestRunningNodes(StepsStore):
    @pytest.mark.smoke
    def test_store_lightpushed_message(self):
        self.setup_first_publishing_node(store="true", relay="true", lightpush="true")
        self.setup_second_publishing_node(store="false", relay="true")
        self.setup_first_store_node(store="false", relay="true", lightpush="true", lightpushnode=self.multiaddr_list[0])
        self.subscribe_to_pubsub_topics_via_relay()
        self.publish_message(via="lightpush", sender=self.store_node1)
        self.check_published_message_is_stored(page_size=5, ascending="true")
