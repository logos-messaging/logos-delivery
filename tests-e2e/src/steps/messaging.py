import base64
import inspect
from time import sleep, time

import pytest
from src.env_vars import NODE_1, NODE_2
from src.libs.common import to_base64
from src.libs.custom_logger import get_custom_logger
from src.node.waku_node import WakuNode
from src.steps.common import StepsCommon
from src.steps.metrics import StepsMetrics

logger = get_custom_logger(__name__)


class StepsMessaging(StepsCommon, StepsMetrics):
    """Drives the messaging REST API (/messaging/v1) on docker nodes.

    node1 runs the Store service and is the Store peer of node2. Both run
    --entry-layer=messaging with one autosharded shard. A poll clears what it
    returns, so the collect_* helpers add up the records of several polls.
    """

    test_content_topic = "/test/1/messaging-rest/proto"
    test_payload = "Messaging works!!"

    @pytest.fixture(scope="function", autouse=True)
    def messaging_setup(self):
        logger.debug(f"Running fixture setup: {inspect.currentframe().f_code.co_name}")
        self.main_nodes = []

    @pytest.fixture(scope="function")
    def setup_main_messaging_nodes(self):
        logger.debug(f"Running fixture setup: {inspect.currentframe().f_code.co_name}")
        self.setup_store_messaging_node()
        self.setup_client_messaging_node()

    def messaging_args(self, **kwargs):
        args = {"entry_layer": "messaging", "mode": "core", "num_shards_in_network": "1"}
        args.update(kwargs)
        return args

    def setup_store_messaging_node(self, **kwargs):
        self.node1 = WakuNode(NODE_1, f"node1_{self.test_id}")
        self.node1.start(**self.messaging_args(store="true", **kwargs))
        self.multiaddr_with_id = self.node1.get_multiaddr_with_id()
        self.main_nodes.append(self.node1)

    def setup_client_messaging_node(self, **kwargs):
        self.node2 = WakuNode(NODE_2, f"node2_{self.test_id}")
        self.node2.start(**self.messaging_args(staticnode=self.multiaddr_with_id, storenode=self.multiaddr_with_id, **kwargs))
        self.main_nodes.append(self.node2)
        self.wait_for_autoconnection(self.main_nodes)

    def messaging_message(self, text=None, **kwargs):
        message = {"payload": to_base64(self.test_payload if text is None else text), "contentTopic": self.test_content_topic}
        message.update(kwargs)
        return message

    def send_and_get_request_id(self, node, text=None, timeout=10, **kwargs):
        """Sends a message and returns its message hash, the id of the send events.

        A 429 with QueueFull means that the node already has its maximum of sends with no
        last event, so the send is made again.
        """
        deadline = time() + timeout
        while True:
            try:
                response = node.messaging_send(self.messaging_message(text, **kwargs))
                break
            except Exception as ex:
                error = str(ex)
                queue_full = error.startswith("Error: 429 ") and "QueueFull" in error
                if not queue_full or time() >= deadline:
                    raise
                sleep(0.2)
        assert response.get("messageHash"), f"no messageHash in send response {response}"
        return response["messageHash"]

    def collect_received(self, node, count, timeout=30):
        """Polls the received endpoint until it has `count` records."""
        records = []
        deadline = time() + timeout
        while len(records) < count and time() < deadline:
            records.extend(node.messaging_received())
            if len(records) < count:
                sleep(0.5)
        assert len(records) >= count, f"collected {len(records)} received records, expected {count}"
        return records

    def collect_send_kinds(self, node, request_id, kinds, timeout=30):
        """Polls the send events of `request_id` until every kind in `kinds` appears.

        A 404 means that nothing is buffered yet. The status is matched at the start of the
        error text, because the URL in the text contains random digits.
        """
        seen = set()
        deadline = time() + timeout
        while not set(kinds) <= seen and time() < deadline:
            try:
                status = node.messaging_send_events_by_id(request_id)
                seen.update(event["kind"] for event in status["events"])
            except Exception as ex:
                if not str(ex).startswith("Error: 404 "):
                    raise
            if not set(kinds) <= seen:
                sleep(0.5)
        assert set(kinds) <= seen, f"send events for {request_id}: saw {sorted(seen)}, expected {kinds}"
        return seen

    def collect_send_events(self, node, request_id, timeout=30):
        """Polls the send events of `request_id` until a "sent" or "error" event comes, the last one of a send.

        Returns the (kind, error) pair of each event, in order; only an "error" event has an error text.
        A 404 means that nothing is buffered yet.
        """
        events = []
        deadline = time() + timeout
        while not any(kind in ("sent", "error") for kind, _ in events) and time() < deadline:
            try:
                status = node.messaging_send_events_by_id(request_id)
                events.extend((event["kind"], event.get("error")) for event in status["events"])
            except Exception as ex:
                if not str(ex).startswith("Error: 404 "):
                    raise
            if not any(kind in ("sent", "error") for kind, _ in events):
                sleep(0.5)
        assert any(kind in ("sent", "error") for kind, _ in events), f"send events for {request_id}: saw {events}, no sent or error"
        return events

    def collect_sent_request_ids(self, node, count, timeout=60):
        """Polls all send events until `count` request ids have a "sent" event."""
        sent = set()
        deadline = time() + timeout
        while len(sent) < count and time() < deadline:
            for status in node.messaging_send_events():
                if any(event["kind"] == "sent" for event in status["events"]):
                    sent.add(status["messageHash"])
            if len(sent) < count:
                sleep(1)
        assert len(sent) == count, f"{len(sent)} of {count} sends confirmed 'sent' within {timeout}s"
        return sent

    def wait_for_live_received_count(self, node, count, timeout=30):
        """Waits until the metrics of `node` report `count` live deliveries."""
        self.wait_for_metric(node, 'logos_delivery_recv_messages_total{source="live"}', count, timeout_duration=timeout)

    def decode_payload(self, record):
        return base64.b64decode(record["message"]["payload"]).decode()
