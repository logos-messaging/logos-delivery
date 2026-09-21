import pytest
from src.libs.common import to_base64, wait_until
from src.steps.store import StepsStore


@pytest.mark.usefixtures("node_setup")
class TestCursorManyMessages(StepsStore):
    def test_get_multiple_2000_store_messages(self):
        expected_message_hash_list = []
        for i in range(2000):
            message = self.create_message(payload=to_base64(f"Message_{i}"))
            self.publish_message(message=message, message_propagation_delay=0)
            expected_message_hash_list.append(self.compute_message_hash(self.test_pubsub_topic, message, hash_type="hex"))
        response_message_hash_list = []

        def all_messages_stored():
            response_message_hash_list.clear()
            cursor = None
            while True:
                store_response = self.get_messages_from_store(self.store_node1, page_size=100, cursor=cursor)
                for index in range(len(store_response.messages)):
                    response_message_hash_list.append(store_response.message_hash(index))
                cursor = store_response.pagination_cursor
                if cursor is None or len(response_message_hash_list) > len(expected_message_hash_list):
                    return len(response_message_hash_list) >= len(expected_message_hash_list)

        wait_until(all_messages_stored, timeout_duration=60, time_between_retries=1, message="Expected 2000 stored messages")
        assert len(expected_message_hash_list) == len(response_message_hash_list), "Message count mismatch"
        assert expected_message_hash_list == response_message_hash_list, "Message hash mismatch"
