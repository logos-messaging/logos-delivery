import base64
import re
import time

from src.libs.common import delay, to_base64
from src.node.subprocess_node import ChannelSenderProcess
from src.node.wrappers_manager import WrapperManager
from src.node.wrapper_helpers import (
    EventCollector,
    create_message_bindings,
    get_node_multiaddr,
    unique_channel_id,
    wait_for_connected,
)

RC05_CHANNEL_PREFIX = "rc05-channel"
CONTENT_TOPIC = "/test/1/rc05-channel/proto"
SENDER_A = "rc05-sender-a"
SENDER_B = "rc05-sender-b"

CHANNEL_RECEIVED_EVENT = "channel_message_received"
MESSAGE_RECEIVED_EVENT = "message_received"

RC06_CHANNEL_PREFIX = "rc06-channel"
RC06_CONTENT_TOPIC = "/test/1/rc06-channel/proto"

RC07_CHANNEL_PREFIX = "rc07-channel"
RC07_CONTENT_TOPIC = "/test/1/rc07-channel/proto"
RC07_OTHER_CONTENT_TOPIC = "/test/1/rc07-other/proto"

RC08_CHANNEL_PREFIX = "rc08-channel"
RC08_CONTENT_TOPIC = "/test/1/rc08-channel/proto"
# Let the delivery settle before replying, so the exchange is interleaved rather
# than two sends racing each other.
RC08_INTERLEAVE_SETTLE_S = 5

RC09_CHANNEL_PREFIX = "rc09-channel"
RC09_CONTENT_TOPIC = "/test/1/rc09-channel/proto"

RC10_CHANNEL_PREFIX = "rc10-channel"
RC10_CONTENT_TOPIC = "/test/1/rc10-channel/proto"
# B's channel must exist before A's second send, or m2 lands with nothing to park it.
RC10_CHANNEL_SETTLE_S = 5

RC12_CHANNEL_PREFIX = "rc12-channel"
RC12_CONTENT_TOPIC = "/test/1/rc12-channel/proto"
SENDER_C = "rc12-sender-c"

RC13_CHANNEL_PREFIX = "rc13-channel"
RC13_CONTENT_TOPIC = "/test/1/rc13-channel/proto"

CLOSED_CHANNEL_PREFIX = "rc-closed-channel"
CLOSED_CONTENT_TOPIC = "/test/1/rc-closed-channel/proto"

MESH_SETTLE_S = 10
DELIVERY_TIMEOUT_S = 50.0
# Once the unmarked message has provably reached B's messaging layer, the
# channel ingress decision has already been made on that same event, so this is
# just a short grace window to catch any late channel_message_received.
NO_CHANNEL_DELIVERY_WINDOW_S = 10.0

# A has no peer to dial before it sends, so no mesh to settle.
RC09_SENDER_SETTLE_S = 2
RC09_RECOVERY_TIMEOUT_S = 90.0


def wait_for_channel_received(collector, channel_id, timeout_s, poll_interval_s=0.5):
    deadline = time.monotonic() + timeout_s
    while True:
        for event in collector.snapshot():
            if event.get("eventType") == CHANNEL_RECEIVED_EVENT and event.get("channelId") == channel_id:
                return event
        if time.monotonic() >= deadline:
            return None
        time.sleep(poll_interval_s)


def wait_for_channel_received_count(collector, channel_id, count, timeout_s, poll_interval_s=0.5):
    """Channel events for `channel_id`, oldest first; waits for `count` of them.

    Returns whatever has arrived when the timeout expires, so a caller can
    assert on both the order and the shortfall.
    """
    deadline = time.monotonic() + timeout_s
    while True:
        received = [e for e in collector.snapshot() if e.get("eventType") == CHANNEL_RECEIVED_EVENT and e.get("channelId") == channel_id]
        if len(received) >= count or time.monotonic() >= deadline:
            return received
        time.sleep(poll_interval_s)


def channel_payloads(events):
    """Decoded payloads of channel events, oldest first."""
    return [base64.b64decode(event["payload"]) for event in events]


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


def wire_payload(event):
    """The SDS envelope an event carried; the FFI sends it as an array of bytes."""
    return bytes((event.get("message") or {}).get("payload") or ())


SDS_MESSAGE_ID_RE = re.compile(rb"[0-9a-f]{64}")


def envelope_message_ids(envelope):
    """SDS message ids in an envelope: its own first, then its causal history.

    Ids are 64-char hex strings the minprotobuf embeds verbatim, and no other
    field can produce that run — the bloom filter stores hashed bits, not ids.
    Channel encryption is a noop (`setNoopEncryption`), so the envelope reaches
    a message_received event in the clear.
    """
    return SDS_MESSAGE_ID_RE.findall(envelope)


def wait_for_distinct_message_received(collector, content_topic, count, timeout_s, poll_interval_s=0.5):
    """Distinct-envelope events on `content_topic`, oldest first; waits for `count`.

    Keyed on the envelope so a rebroadcast, which is a fresh message_received
    carrying the same bytes, cannot pass for a second message.
    """
    deadline = time.monotonic() + timeout_s
    while True:
        received = {}
        for event in collector.snapshot():
            if event.get("eventType") == MESSAGE_RECEIVED_EVENT and (event.get("message") or {}).get("contentTopic") == content_topic:
                received.setdefault(wire_payload(event), event)
        if len(received) >= count or time.monotonic() >= deadline:
            return list(received.values())
        time.sleep(poll_interval_s)


class TestChannelDelivery:
    def test_rc05_basic_a_to_b_delivery(self, node_config):
        """RC05: A's channel send is delivered to B on the matching channel + topic.

        Relay-only (store + reliability off). B must fire a channel_message_received
        event carrying the payload intact and tagged with A's senderId.

        A runs in a separate, storage-isolated process: nodes sharing a storage path
        make B drop A's message as a duplicate. See src/node/subprocess_node.py.
        """
        channel_id = unique_channel_id(RC05_CHANNEL_PREFIX)
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

            receiver_create = receiver.channel_create(channel_id, CONTENT_TOPIC, SENDER_B)
            assert receiver_create.is_ok(), f"receiver channel_create failed: {receiver_create.err()}"

            with ChannelSenderProcess(
                sender_config,
                content_topic=CONTENT_TOPIC,
                channel_id=channel_id,
                sender_id=SENDER_A,
                payload_b64=payload_b64,
                settle_s=MESH_SETTLE_S,
            ):
                received = wait_for_channel_received(receiver_collector, channel_id, DELIVERY_TIMEOUT_S)
                assert received is not None, (
                    f"No {CHANNEL_RECEIVED_EVENT} on B for {channel_id} within {DELIVERY_TIMEOUT_S}s. "
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
        channel_id = unique_channel_id(RC06_CHANNEL_PREFIX)
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
                receiver_create = receiver.channel_create(channel_id, RC06_CONTENT_TOPIC, SENDER_B)
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
                leaked = wait_for_channel_received(receiver_collector, channel_id, NO_CHANNEL_DELIVERY_WINDOW_S)
                assert leaked is None, f"an unmarked message must not surface as a {CHANNEL_RECEIVED_EVENT}; got: {leaked!r}"

    def test_rc07_wrong_content_topic_dropped(self, node_config):
        """RC07: a correctly-marked channel message published on a different
        content topic is dropped at channel ingress.

        A runs the same channelId as B but on RC07_OTHER_CONTENT_TOPIC. B is
        subscribed to that topic too, so B's messaging layer still surfaces the
        message (message_received), proving it arrived, but B's channel is bound
        to RC07_CONTENT_TOPIC and must not fire channel_message_received.
        """
        channel_id = unique_channel_id(RC07_CHANNEL_PREFIX)
        payload_b64 = to_base64("rc07 message on the wrong content topic")

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

            for content_topic in (RC07_CONTENT_TOPIC, RC07_OTHER_CONTENT_TOPIC):
                subscribe_result = receiver.subscribe_content_topic(content_topic)
                assert subscribe_result.is_ok(), f"receiver subscribe_content_topic {content_topic} failed: {subscribe_result.err()}"

            receiver_create = receiver.channel_create(channel_id, RC07_CONTENT_TOPIC, SENDER_B)
            assert receiver_create.is_ok(), f"receiver channel_create failed: {receiver_create.err()}"

            with ChannelSenderProcess(
                sender_config,
                content_topic=RC07_OTHER_CONTENT_TOPIC,
                channel_id=channel_id,
                sender_id=SENDER_A,
                payload_b64=payload_b64,
                settle_s=MESH_SETTLE_S,
            ):
                arrived = wait_for_message_received(receiver_collector, RC07_OTHER_CONTENT_TOPIC, DELIVERY_TIMEOUT_S)
                assert arrived is not None, (
                    f"receiver never saw a {MESSAGE_RECEIVED_EVENT} for {RC07_OTHER_CONTENT_TOPIC} within {DELIVERY_TIMEOUT_S}s; "
                    f"cannot conclude the channel dropped it. Collected events: {receiver_collector.snapshot()}"
                )

                leaked = wait_for_channel_received(receiver_collector, channel_id, NO_CHANNEL_DELIVERY_WINDOW_S)
                assert leaked is None, f"a message on a foreign content topic must not surface as a {CHANNEL_RECEIVED_EVENT}; got: {leaked!r}"

    def test_rc08_bidirectional_exchange_delivers_both_ways(self, node_config):
        """RC08: A and B exchange interleaved messages on one channel, both
        directions deliver, and m3 carries m1 in its causal history.

        Arrival order alone proves nothing here — each send waits for the
        previous message to land, so [m1, m3] would hold with causal history
        switched off entirely. The causal claim is therefore checked against the
        wire: when A sends m3 its SDS history holds m1 (sent) and m2 (received),
        so m3's envelope must reference m1's message id. Parking and release of
        an out-of-order dependency are covered by
        test_rc10_missing_dependency_is_parked and test_channel_repair.py.
        """
        channel_id = unique_channel_id(RC08_CHANNEL_PREFIX)
        m1, m2, m3 = "rc08 from A", "rc08 reply from B", "rc08 follow-up from A"

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

            subscribe_result = receiver.subscribe_content_topic(RC08_CONTENT_TOPIC)
            assert subscribe_result.is_ok(), f"receiver subscribe_content_topic failed: {subscribe_result.err()}"

            receiver_create = receiver.channel_create(channel_id, RC08_CONTENT_TOPIC, SENDER_B)
            assert receiver_create.is_ok(), f"receiver channel_create failed: {receiver_create.err()}"

            with ChannelSenderProcess(
                sender_config,
                content_topic=RC08_CONTENT_TOPIC,
                channel_id=channel_id,
                sender_id=SENDER_A,
                payload_b64=to_base64(m1),
                settle_s=MESH_SETTLE_S,
            ) as sender:
                first = wait_for_channel_received(receiver_collector, channel_id, DELIVERY_TIMEOUT_S)
                assert first is not None, (
                    f"B never saw A's first message within {DELIVERY_TIMEOUT_S}s; "
                    f"nothing to reply to. Collected events: {receiver_collector.snapshot()}"
                )

                # B replies only now, so the exchange is genuinely interleaved.
                delay(RC08_INTERLEAVE_SETTLE_S)
                reply_result = receiver.channel_send(channel_id, create_message_bindings(payload=to_base64(m2)))
                assert reply_result.is_ok(), f"receiver channel_send failed: {reply_result.err()}"

                delivered_to_a = sender.wait_for_received(1, DELIVERY_TIMEOUT_S)
                assert channel_payloads(delivered_to_a) == [m2.encode()], f"A must deliver B's reply; got {channel_payloads(delivered_to_a)!r}"

                # Same race on A's side.
                delay(RC08_INTERLEAVE_SETTLE_S)
                sender.send(to_base64(m3))

                delivered_to_b = wait_for_channel_received_count(receiver_collector, channel_id, 2, DELIVERY_TIMEOUT_S)
                assert channel_payloads(delivered_to_b) == [m1.encode(), m3.encode()], (
                    f"B must deliver both of A's messages, in send order; got {channel_payloads(delivered_to_b)!r}. "
                    f"Collected events: {receiver_collector.snapshot()}"
                )

                envelopes = [wire_payload(e) for e in wait_for_distinct_message_received(receiver_collector, RC08_CONTENT_TOPIC, 2, DELIVERY_TIMEOUT_S)]
                m1_envelope = next((e for e in envelopes if m1.encode() in e), None)
                m3_envelope = next((e for e in envelopes if m3.encode() in e), None)
                assert m1_envelope and m3_envelope, f"B must have seen both envelopes on the wire; got {envelopes!r}"

                m1_ids = envelope_message_ids(m1_envelope)
                assert m1_ids, f"no SDS message id in m1's envelope: {m1_envelope!r}"
                m3_ids = envelope_message_ids(m3_envelope)
                assert m1_ids[0] in m3_ids[1:], (
                    f"m3 must carry m1 in its causal history; m1 is {m1_ids[0]!r}, "
                    f"m3's envelope references {m3_ids[1:]!r}"
                )

    def test_rc09_late_joining_receiver_still_receives(self, node_config):
        """RC09: A sends m1 while B is not up yet; B joins and still ends up with
        both m1 and m2.

        Recovery here is the send service's relay retry, not SDS: A republishes
        m1 while it is unacknowledged (within MaxTimeInCache) and it lands as
        soon as B joins the mesh. SDS-R is not exercised — a repair request only
        rides out after T_req, a hash in [repairTMin, repairTMax) = [30s, 300s)
        that logos-delivery does not expose, so it cannot be driven from an E2E
        test. That path is RC10 — see test_rc10_missing_dependency_is_parked
        below and tests/wrappers_tests/test_channel_repair.py.
        """
        channel_id = unique_channel_id(RC09_CHANNEL_PREFIX)
        m1, m2 = "rc09 sent while B is away", "rc09 sent after B joins"

        node_config.update(
            {
                "relay": True,
                "store": False,
                "reliabilityEnabled": False,
                "numShardsInNetwork": 1,
            }
        )
        # A comes up first with nobody to dial; B joins later and dials A.
        sender_config = {**node_config, "portsShift": 1}

        with ChannelSenderProcess(
            sender_config,
            content_topic=RC09_CONTENT_TOPIC,
            channel_id=channel_id,
            sender_id=SENDER_A,
            payload_b64=to_base64(m1),
            settle_s=RC09_SENDER_SETTLE_S,
        ) as sender:
            receiver_collector = EventCollector()
            receiver_config = {**node_config, "staticnodes": [sender.multiaddr]}
            receiver_result = WrapperManager.create_and_start(config=receiver_config, event_cb=receiver_collector.event_callback)
            assert receiver_result.is_ok(), f"Failed to start receiver: {receiver_result.err()}"

            with receiver_result.ok_value as receiver:
                assert wait_for_connected(receiver_collector) is not None, "Receiver did not reach Connected/PartiallyConnected state"

                subscribe_result = receiver.subscribe_content_topic(RC09_CONTENT_TOPIC)
                assert subscribe_result.is_ok(), f"receiver subscribe_content_topic failed: {subscribe_result.err()}"

                receiver_create = receiver.channel_create(channel_id, RC09_CONTENT_TOPIC, SENDER_B)
                assert receiver_create.is_ok(), f"receiver channel_create failed: {receiver_create.err()}"

                delay(MESH_SETTLE_S)

                sender.send(to_base64(m2))

                recovered = wait_for_channel_received_count(receiver_collector, channel_id, 2, RC09_RECOVERY_TIMEOUT_S)
                assert channel_payloads(recovered) == [m1.encode(), m2.encode()], (
                    f"B must end up with the message sent before it joined, then the one after; "
                    f"got {channel_payloads(recovered)!r}. Collected events: {receiver_collector.snapshot()}"
                )

    def test_rc10_missing_dependency_is_parked(self, node_config):
        """RC10 setup: a message whose causal dependency B never saw is parked,
        not delivered.

        B is connected and subscribed throughout but has no channel when A sends
        m1, so m1 stops at B's messaging layer. B then creates the channel and A
        sends m2, which carries m1 in its causal history: message_received proves
        m2 arrived, and the absence of a channel event proves SDS parked it.

        Recovery from here is SDS-R repair, in test_channel_repair.py.
        """
        channel_id = unique_channel_id(RC10_CHANNEL_PREFIX)
        m1, m2 = "rc10 sent before B has a channel", "rc10 depends on m1"

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

            subscribe_result = receiver.subscribe_content_topic(RC10_CONTENT_TOPIC)
            assert subscribe_result.is_ok(), f"receiver subscribe_content_topic failed: {subscribe_result.err()}"

            with ChannelSenderProcess(
                sender_config,
                content_topic=RC10_CONTENT_TOPIC,
                channel_id=channel_id,
                sender_id=SENDER_A,
                payload_b64=to_base64(m1),
                settle_s=MESH_SETTLE_S,
            ) as sender:
                arrived = wait_for_message_received(receiver_collector, RC10_CONTENT_TOPIC, DELIVERY_TIMEOUT_S)
                assert arrived is not None, (
                    f"receiver never saw a {MESSAGE_RECEIVED_EVENT} for m1 within {DELIVERY_TIMEOUT_S}s; "
                    f"the dependency was never established. Collected events: {receiver_collector.snapshot()}"
                )

                leaked = wait_for_channel_received(receiver_collector, channel_id, NO_CHANNEL_DELIVERY_WINDOW_S)
                assert leaked is None, f"a node with no channel must not emit {CHANNEL_RECEIVED_EVENT}; got: {leaked!r}"

                receiver_create = receiver.channel_create(channel_id, RC10_CONTENT_TOPIC, SENDER_B)
                assert receiver_create.is_ok(), f"receiver channel_create failed: {receiver_create.err()}"

                delay(RC10_CHANNEL_SETTLE_S)

                sender.send(to_base64(m2))

                both = wait_for_distinct_message_received(receiver_collector, RC10_CONTENT_TOPIC, 2, DELIVERY_TIMEOUT_S)
                assert len(both) == 2, (
                    f"receiver must see m2 at the messaging layer within {DELIVERY_TIMEOUT_S}s; "
                    f"got {len(both)} distinct {MESSAGE_RECEIVED_EVENT} envelopes. "
                    f"Collected events: {receiver_collector.snapshot()}"
                )
                # Channel encryption is a noop here, so m2's content is on the wire verbatim.
                assert m2.encode() in wire_payload(both[1]), (
                    f"the second envelope must carry m2, not repeat m1; got {wire_payload(both[1])!r}. "
                    f"Collected events: {receiver_collector.snapshot()}"
                )

                parked = wait_for_channel_received(receiver_collector, channel_id, NO_CHANNEL_DELIVERY_WINDOW_S)
                assert parked is None, f"m2 must stay parked while m1 is missing, not surface as {CHANNEL_RECEIVED_EVENT}; got: {parked!r}"

    def test_rc12_three_participants_all_receive(self, node_config):
        """RC12: A, B and C share one channel; A's send reaches both B and C.

        Each delivers m1 exactly once, with A's senderId and the exact payload.
        B is the node under test; A and C run as storage-isolated peers dialing it.
        """
        channel_id = unique_channel_id(RC12_CHANNEL_PREFIX)
        m1 = "rc12 from A"

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
            peer_config = {**node_config, "staticnodes": [get_node_multiaddr(receiver)]}

            subscribe_result = receiver.subscribe_content_topic(RC12_CONTENT_TOPIC)
            assert subscribe_result.is_ok(), f"receiver subscribe_content_topic failed: {subscribe_result.err()}"

            receiver_create = receiver.channel_create(channel_id, RC12_CONTENT_TOPIC, SENDER_B)
            assert receiver_create.is_ok(), f"receiver channel_create failed: {receiver_create.err()}"

            # C joins first so it is meshed by the time A sends m1.
            with ChannelSenderProcess(
                {**peer_config, "portsShift": 2},
                content_topic=RC12_CONTENT_TOPIC,
                channel_id=channel_id,
                sender_id=SENDER_C,
                settle_s=MESH_SETTLE_S,
            ) as third_party:
                with ChannelSenderProcess(
                    {**peer_config, "portsShift": 1},
                    content_topic=RC12_CONTENT_TOPIC,
                    channel_id=channel_id,
                    sender_id=SENDER_A,
                    payload_b64=to_base64(m1),
                    settle_s=MESH_SETTLE_S,
                ):
                    assert (
                        wait_for_channel_received(receiver_collector, channel_id, DELIVERY_TIMEOUT_S) is not None
                    ), f"B never saw A's message within {DELIVERY_TIMEOUT_S}s. Collected events: {receiver_collector.snapshot()}"
                    assert third_party.wait_for_received(1, DELIVERY_TIMEOUT_S), f"C never saw A's message within {DELIVERY_TIMEOUT_S}s"

                    # B and C must have exactly one delivery; any second event is a duplicate.
                    on_b = wait_for_channel_received_count(receiver_collector, channel_id, 2, NO_CHANNEL_DELIVERY_WINDOW_S)
                    on_c = third_party.wait_for_received(2, NO_CHANNEL_DELIVERY_WINDOW_S)

                    assert channel_payloads(on_b) == [m1.encode()], f"B must deliver A's message exactly once; got {channel_payloads(on_b)!r}"
                    assert channel_payloads(on_c) == [m1.encode()], f"C must deliver A's message exactly once; got {channel_payloads(on_c)!r}"
                    assert [e["senderId"] for e in on_b + on_c] == [
                        SENDER_A,
                        SENDER_A,
                    ], f"both events must carry {SENDER_A!r}, got {[e.get('senderId') for e in on_b + on_c]!r}"

    def test_rc13_close_recreate_then_send_delivers_new_message(self, node_config):
        """RC13: A closes and re-creates its channel, then sends again.

        A sends m1, cycles the channel under the same id, then sends m2. B must
        deliver m2 exactly once, after m1, and must not replay m1. Whether the
        re-created channel restored A's SDS history or started a fresh one is
        not distinguishable here — both satisfy these assertions.

        Distinct from the nim in-process test, which cycles the *receiver's*
        channel and asserts a replayed m1 is suppressed on ingress; here the
        cycle is on the send path.
        """
        channel_id = unique_channel_id(RC13_CHANNEL_PREFIX)
        m1, m2 = "rc13 before close", "rc13 after re-create"

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

            subscribe_result = receiver.subscribe_content_topic(RC13_CONTENT_TOPIC)
            assert subscribe_result.is_ok(), f"receiver subscribe_content_topic failed: {subscribe_result.err()}"

            receiver_create = receiver.channel_create(channel_id, RC13_CONTENT_TOPIC, SENDER_B)
            assert receiver_create.is_ok(), f"receiver channel_create failed: {receiver_create.err()}"

            with ChannelSenderProcess(
                sender_config,
                content_topic=RC13_CONTENT_TOPIC,
                channel_id=channel_id,
                sender_id=SENDER_A,
                payload_b64=to_base64(m1),
                settle_s=MESH_SETTLE_S,
            ) as sender:
                first = wait_for_channel_received(receiver_collector, channel_id, DELIVERY_TIMEOUT_S)
                assert first is not None, (
                    f"No {CHANNEL_RECEIVED_EVENT} for m1 on {channel_id} within {DELIVERY_TIMEOUT_S}s; "
                    f"the close/re-create is only meaningful once m1 landed. Collected events: {receiver_collector.snapshot()}"
                )

                sender.close_and_recreate()
                sender.send(to_base64(m2))

                received = wait_for_channel_received_count(receiver_collector, channel_id, 2, DELIVERY_TIMEOUT_S)
                assert len(received) == 2, (
                    f"expected m1 then m2 on {channel_id}, got {len(received)}: {channel_payloads(received)!r}. "
                    f"Collected events: {receiver_collector.snapshot()}"
                )
                assert channel_payloads(received) == [
                    m1.encode(),
                    m2.encode(),
                ], f"expected [m1, m2] in send order, got: {channel_payloads(received)!r}"

                # A third event could only be a replayed m1 from the re-created channel.
                settled = wait_for_channel_received_count(receiver_collector, channel_id, 3, NO_CHANNEL_DELIVERY_WINDOW_S)
                assert len(settled) == 2, f"re-create must not re-deliver m1; got: {channel_payloads(settled)!r}"

    def test_receive_after_close_emits_no_channel_event(self, node_config):
        """A closed channel must not deliver: B closes its channel, then A sends a
        valid channel message on the same channel + content topic.

        B stays subscribed to the content topic, so B's messaging layer still
        surfaces the message (message_received), proving it arrived, but the
        closed channel must not fire channel_message_received.

        channel_close unsubscribes the content topic (logos-delivery#4081), so B
        re-subscribes to keep message_received as the witness.
        """
        channel_id = unique_channel_id(CLOSED_CHANNEL_PREFIX)
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

            receiver_create = receiver.channel_create(channel_id, CLOSED_CONTENT_TOPIC, SENDER_B)
            assert receiver_create.is_ok(), f"receiver channel_create failed: {receiver_create.err()}"

            receiver_close = receiver.channel_close(channel_id)
            assert receiver_close.is_ok(), f"receiver channel_close failed: {receiver_close.err()}"

            resubscribe_result = receiver.subscribe_content_topic(CLOSED_CONTENT_TOPIC)
            assert resubscribe_result.is_ok(), f"receiver re-subscribe after close failed: {resubscribe_result.err()}"

            with ChannelSenderProcess(
                sender_config,
                content_topic=CLOSED_CONTENT_TOPIC,
                channel_id=channel_id,
                sender_id=SENDER_A,
                payload_b64=payload_b64,
                settle_s=MESH_SETTLE_S,
            ):
                arrived = wait_for_message_received(receiver_collector, CLOSED_CONTENT_TOPIC, DELIVERY_TIMEOUT_S)
                assert arrived is not None, (
                    f"receiver never saw a {MESSAGE_RECEIVED_EVENT} for {CLOSED_CONTENT_TOPIC} within {DELIVERY_TIMEOUT_S}s; "
                    f"cannot conclude the closed channel stayed silent. Collected events: {receiver_collector.snapshot()}"
                )

                leaked = wait_for_channel_received(receiver_collector, channel_id, NO_CHANNEL_DELIVERY_WINDOW_S)
                assert leaked is None, f"a closed channel must not emit {CHANNEL_RECEIVED_EVENT}; got: {leaked!r}"
