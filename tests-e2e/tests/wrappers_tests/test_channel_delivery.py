import base64
import time

from src.libs.common import delay, to_base64
from src.node.subprocess_node import ChannelSenderProcess
from src.node.wrappers_manager import WrapperManager
from src.node.wrapper_helpers import (
    EventCollector,
    create_message_bindings,
    get_node_multiaddr,
    wait_for_connected,
)

CHANNEL_ID = "rc05-channel"
CONTENT_TOPIC = "/test/1/rc05-channel/proto"
SENDER_A = "rc05-sender-a"
SENDER_B = "rc05-sender-b"

CHANNEL_RECEIVED_EVENT = "channel_message_received"
MESSAGE_RECEIVED_EVENT = "message_received"

RC06_CHANNEL_ID = "rc06-channel"
RC06_CONTENT_TOPIC = "/test/1/rc06-channel/proto"

CLOSED_CHANNEL_ID = "rc-closed-channel"
CLOSED_CONTENT_TOPIC = "/test/1/rc-closed-channel/proto"

MESH_SETTLE_S = 10
DELIVERY_TIMEOUT_S = 50.0
# Once the unmarked message has provably reached B's messaging layer, the
# channel ingress decision has already been made on that same event, so this is
# just a short grace window to catch any late channel_message_received.
NO_CHANNEL_DELIVERY_WINDOW_S = 10.0


def wait_for_channel_received(collector, channel_id, timeout_s, poll_interval_s=0.5):
    deadline = time.monotonic() + timeout_s
    while True:
        for event in collector.snapshot():
            if event.get("eventType") == CHANNEL_RECEIVED_EVENT and event.get("channelId") == channel_id:
                return event
        if time.monotonic() >= deadline:
            return None
        time.sleep(poll_interval_s)


def wait_for_message_received(collector, content_topic, timeout_s, poll_interval_s=0.5):
    """Wait for a messaging-layer message_received event on `content_topic`.

    Used to prove a raw relay message actually reached the receiver, independent
    of the channel layer (the content topic lives under the nested `message`).
    """
    deadline = time.monotonic() + timeout_s
    while True:
        for event in collector.snapshot():
            if event.get("eventType") == MESSAGE_RECEIVED_EVENT and (event.get("message") or {}).get("contentTopic") == content_topic:
                return event
        if time.monotonic() >= deadline:
            return None
        time.sleep(poll_interval_s)


class TestChannelDelivery:
    def test_rc05_basic_a_to_b_delivery(self, node_config):
        """RC05: A's channel send is delivered to B on the matching channel + topic.

        Relay-only (store + reliability off). B must fire a channel_message_received
        event carrying the payload intact and tagged with A's senderId.

        A runs in a separate, storage-isolated process: nodes sharing a storage path
        make B drop A's message as a duplicate. See src/node/subprocess_node.py.
        """
        payload_b64 = to_base64("rc05 hello from A")

        node_config.update(
            {
                "relay": True,
                "store": False,
                "reliabilityEnabled": False,
                "numShardsInNetwork": 1,
            }
        )

        receiver_collector = EventCollector()
        receiver_result = WrapperManager.create_and_start(config=node_config, event_cb=receiver_collector.event_callback)
        assert receiver_result.is_ok(), f"Failed to start receiver: {receiver_result.err()}"

        with receiver_result.ok_value as receiver:
            sender_config = {
                **node_config,
                "staticnodes": [get_node_multiaddr(receiver)],
                "portsShift": 1,
            }

            subscribe_result = receiver.subscribe_content_topic(CONTENT_TOPIC)
            assert subscribe_result.is_ok(), f"receiver subscribe_content_topic failed: {subscribe_result.err()}"

            receiver_create = receiver.channel_create(CHANNEL_ID, CONTENT_TOPIC, SENDER_B)
            assert receiver_create.is_ok(), f"receiver channel_create failed: {receiver_create.err()}"

            with ChannelSenderProcess(
                sender_config,
                content_topic=CONTENT_TOPIC,
                channel_id=CHANNEL_ID,
                sender_id=SENDER_A,
                payload_b64=payload_b64,
                settle_s=MESH_SETTLE_S,
            ):
                received = wait_for_channel_received(receiver_collector, CHANNEL_ID, DELIVERY_TIMEOUT_S)
                assert received is not None, (
                    f"No {CHANNEL_RECEIVED_EVENT} on B for {CHANNEL_ID} within {DELIVERY_TIMEOUT_S}s. "
                    f"Collected events: {receiver_collector.snapshot()}"
                )
                assert base64.b64decode(received["payload"]) == base64.b64decode(
                    payload_b64
                ), f"delivered payload mismatch: got {received['payload']!r}, sent {payload_b64!r}"
                assert (
                    received["senderId"] == SENDER_A
                ), f"received event must carry the originator's senderId {SENDER_A!r}, got {received.get('senderId')!r}"

    def test_rc06_missing_marker_dropped(self, node_config):
        """RC06: a plain message on the channel's content topic but without the
        Reliable-Channel spec marker is dropped at channel ingress.

        A publishes a raw relay message (no RELIABLE-CHANNEL-API/1 meta) on B's
        content topic. B's messaging layer still surfaces it (message_received),
        proving the message arrived, but the channel ingress filter drops it: no
        channel_message_received fires for the channel.
        """
        payload_b64 = to_base64("rc06 unmarked message")

        node_config.update(
            {
                "relay": True,
                "store": False,
                "reliabilityEnabled": False,
                "numShardsInNetwork": 1,
            }
        )

        receiver_collector = EventCollector()
        receiver_result = WrapperManager.create_and_start(config=node_config, event_cb=receiver_collector.event_callback)
        assert receiver_result.is_ok(), f"Failed to start receiver: {receiver_result.err()}"

        with receiver_result.ok_value as receiver:
            sender_config = {
                **node_config,
                "staticnodes": [get_node_multiaddr(receiver)],
                "portsShift": 1,
            }
            sender_collector = EventCollector()
            sender_result = WrapperManager.create_and_start(config=sender_config, event_cb=sender_collector.event_callback)
            assert sender_result.is_ok(), f"Failed to start sender: {sender_result.err()}"

            with sender_result.ok_value as sender:
                assert wait_for_connected(sender_collector) is not None, "Sender did not reach Connected/PartiallyConnected state"

                subscribe_result = receiver.subscribe_content_topic(RC06_CONTENT_TOPIC)
                assert subscribe_result.is_ok(), f"receiver subscribe_content_topic failed: {subscribe_result.err()}"
                subscribe_result = sender.subscribe_content_topic(RC06_CONTENT_TOPIC)
                assert subscribe_result.is_ok(), f"sender subscribe_content_topic failed: {subscribe_result.err()}"

                # Only B runs a channel; A never marks its traffic.
                receiver_create = receiver.channel_create(RC06_CHANNEL_ID, RC06_CONTENT_TOPIC, SENDER_B)
                assert receiver_create.is_ok(), f"receiver channel_create failed: {receiver_create.err()}"

                delay(MESH_SETTLE_S)

                # Plain relay publish: right content topic, but no Reliable-Channel
                # marker, so B's channel ingress filter must drop it.
                send_result = sender.send_message(create_message_bindings(contentTopic=RC06_CONTENT_TOPIC, payload=payload_b64))
                assert send_result.is_ok(), f"send_message failed: {send_result.err()}"

                # It reaches B's messaging layer, so the drop below is the marker
                # filter at work, not a message that simply never arrived.
                arrived = wait_for_message_received(receiver_collector, RC06_CONTENT_TOPIC, DELIVERY_TIMEOUT_S)
                assert arrived is not None, (
                    f"receiver never saw a {MESSAGE_RECEIVED_EVENT} for {RC06_CONTENT_TOPIC} within {DELIVERY_TIMEOUT_S}s; "
                    f"cannot conclude the channel dropped it. Collected events: {receiver_collector.snapshot()}"
                )

                # The channel ingress filter drops the unmarked message: no channel event.
                leaked = wait_for_channel_received(receiver_collector, RC06_CHANNEL_ID, NO_CHANNEL_DELIVERY_WINDOW_S)
                assert leaked is None, f"an unmarked message must not surface as a {CHANNEL_RECEIVED_EVENT}; got: {leaked!r}"

    def test_receive_after_close_emits_no_channel_event(self, node_config):
        """A closed channel must not deliver: B closes its channel, then A sends a
        valid channel message on the same channel + content topic.

        B stays subscribed to the content topic, so B's messaging layer still
        surfaces the message (message_received), proving it arrived, but the
        closed channel must not fire channel_message_received.

        channel_close unsubscribes the content topic (logos-delivery#4081), so B
        re-subscribes to keep message_received as the witness.
        """
        payload_b64 = to_base64("message for a closed channel")

        node_config.update(
            {
                "relay": True,
                "store": False,
                "reliabilityEnabled": False,
                "numShardsInNetwork": 1,
            }
        )

        receiver_collector = EventCollector()
        receiver_result = WrapperManager.create_and_start(config=node_config, event_cb=receiver_collector.event_callback)
        assert receiver_result.is_ok(), f"Failed to start receiver: {receiver_result.err()}"

        with receiver_result.ok_value as receiver:
            sender_config = {
                **node_config,
                "staticnodes": [get_node_multiaddr(receiver)],
                "portsShift": 1,
            }

            subscribe_result = receiver.subscribe_content_topic(CLOSED_CONTENT_TOPIC)
            assert subscribe_result.is_ok(), f"receiver subscribe_content_topic failed: {subscribe_result.err()}"

            receiver_create = receiver.channel_create(CLOSED_CHANNEL_ID, CLOSED_CONTENT_TOPIC, SENDER_B)
            assert receiver_create.is_ok(), f"receiver channel_create failed: {receiver_create.err()}"

            receiver_close = receiver.channel_close(CLOSED_CHANNEL_ID)
            assert receiver_close.is_ok(), f"receiver channel_close failed: {receiver_close.err()}"

            resubscribe_result = receiver.subscribe_content_topic(CLOSED_CONTENT_TOPIC)
            assert resubscribe_result.is_ok(), f"receiver re-subscribe after close failed: {resubscribe_result.err()}"

            with ChannelSenderProcess(
                sender_config,
                content_topic=CLOSED_CONTENT_TOPIC,
                channel_id=CLOSED_CHANNEL_ID,
                sender_id=SENDER_A,
                payload_b64=payload_b64,
                settle_s=MESH_SETTLE_S,
            ):
                arrived = wait_for_message_received(receiver_collector, CLOSED_CONTENT_TOPIC, DELIVERY_TIMEOUT_S)
                assert arrived is not None, (
                    f"receiver never saw a {MESSAGE_RECEIVED_EVENT} for {CLOSED_CONTENT_TOPIC} within {DELIVERY_TIMEOUT_S}s; "
                    f"cannot conclude the closed channel stayed silent. Collected events: {receiver_collector.snapshot()}"
                )

                leaked = wait_for_channel_received(receiver_collector, CLOSED_CHANNEL_ID, NO_CHANNEL_DELIVERY_WINDOW_S)
                assert leaked is None, f"a closed channel must not emit {CHANNEL_RECEIVED_EVENT}; got: {leaked!r}"
