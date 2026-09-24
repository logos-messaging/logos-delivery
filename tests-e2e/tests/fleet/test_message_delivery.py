from src.steps.filter import StepsFilter
from src.steps.fleet import StepsFleet
from src.steps.sharding import StepsSharding


class TestFleetMessageDelivery(StepsFleet, StepsFilter, StepsSharding):
    def test_lightpushed_message_reaches_filter_client(self):
        sender, receiver = self.start_fleet_nodes((self.start_fleet_light_client, "sender"), (self.start_fleet_light_client, "receiver"))
        self.subscribe_through_fleet(receiver)

        message = self.create_message()
        self.light_push_through_fleet(sender, message)

        received = self.wait_for_filter_messages(self.test_content_topic, 1, node=receiver, timeout_duration=60)
        assert [m["payload"] for m in received] == [message["payload"]]

    def test_lightpushed_message_is_stored(self):
        sender, querier = self.start_fleet_nodes((self.start_fleet_light_client, "sender"), (self.start_fleet_light_client, "querier"))

        message = self.create_message()
        self.light_push_through_fleet(sender, message)

        stored = self.wait_for_fleet_store_messages(querier, 1)
        assert [m["message"]["payload"] for m in stored] == [message["payload"]]

    def test_relayed_message_reaches_filter_client(self):
        publisher, receiver = self.start_fleet_nodes((self.start_fleet_relay_node, "publisher"), (self.start_fleet_light_client, "receiver"))
        self.subscribe_through_fleet(receiver)

        message = self.create_message()
        self.relay_publish_through_fleet(publisher, message)

        received = self.wait_for_filter_messages(self.test_content_topic, 1, node=receiver, timeout_duration=60)
        assert [m["payload"] for m in received] == [message["payload"]]

    def test_lightpushed_message_reaches_relay_node(self):
        receiver, sender = self.start_fleet_nodes((self.start_fleet_relay_node, "receiver"), (self.start_fleet_light_client, "sender"))

        message = self.create_message()
        self.light_push_through_fleet(sender, message)

        received = self.wait_for_relay_messages(receiver, 1, content_topic=self.test_content_topic, timeout_duration=60)
        assert [m["payload"] for m in received] == [message["payload"]]
