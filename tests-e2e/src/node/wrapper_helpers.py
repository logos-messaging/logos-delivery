from __future__ import annotations

import base64
import json
import os
import re
import tempfile
import threading
import time
import uuid
from typing import Optional
from src.libs.common import to_base64

DEFAULT_CONTENT_TOPIC = "/test/1/default/proto"
DEFAULT_PAYLOAD = to_base64("test payload")
EVENT_PROPAGATED = "message_propagated"
EVENT_SENT = "message_sent"
EVENT_ERROR = "message_error"
EVENT_CHANNEL_RECEIVED = "channel_message_received"
EVENT_CHANNEL_ERROR = "channel_message_error"
EVENT_TOPIC_HEALTH_CHANGE = "relay_topic_health_change"
# Topic health a node reports once its relay mesh on the shard has at least one peer.
MESH_TOPIC_HEALTH = ("MinimallyHealthy", "SufficientlyHealthy")

# DeliveryWindow and StoreValidationWindow from send_service.nim.
DELIVERY_WINDOW_S = 15.0
STORE_VALIDATION_WINDOW_S = 30.0
# Extra slack to cover the background retry loop tick after a window ends.
WINDOW_SLACK_S = 10.0
ERROR_AFTER_DELIVERY_WINDOW_TIMEOUT_S = DELIVERY_WINDOW_S + WINDOW_SLACK_S
ERROR_AFTER_STORE_VALIDATION_TIMEOUT_S = STORE_VALIDATION_WINDOW_S + WINDOW_SLACK_S
DELIVERY_WINDOW_EXPIRED_MSG = "Unable to send within the delivery window"
STORE_VALIDATION_TIMEOUT_MSG = "Propagated but not confirmed by a store node within the store validation window"
# MessageErrorKind values carried in message_error events.
ERROR_KIND_NOT_PROPAGATED = "NotPropagated"
ERROR_KIND_NOT_STORED = "NotStored"
# SendErrorKind values: a refused send's error text ends with the kind in parentheses.
SEND_REFUSED_NOT_STARTED = "NotStarted"
SEND_REFUSED_NOT_CONNECTED = "NotConnected"
SEND_REFUSED_NO_SHARD = "NoShardMapsContentTopic"
SEND_REFUSED_QUEUE_FULL = "QueueFull"
SEND_REFUSED_RATE_LIMITED = "RateLimited"
SEND_REFUSED_TOO_LARGE = "TooLarge"
MESSAGE_HASH_RE = re.compile(r"0x[0-9a-f]{64}")


class EventCollector:
    """Thread-safe collector for async node events.

    Pass `collector.event_callback` as the `event_cb` argument to
    WrapperManager.create_and_start().  Every event fired by the library
    is decoded from JSON and appended to `self.events`.
    """

    def __init__(self):
        self._lock = threading.Lock()
        self.events: list[dict] = []

    def event_callback(self, ret: int, raw: bytes) -> None:
        try:
            payload = json.loads(raw.decode("utf-8"))
        except Exception:
            payload = {"_raw": raw.decode("utf-8", errors="replace"), "_ret": ret}

        with self._lock:
            self.events.append(payload)

    def get_events_for_message(self, message_hash: str) -> list[dict]:
        with self._lock:
            return [e for e in self.events if e.get("messageHash") == message_hash]

    def get_events_for_channel_request(self, channel_req_id: str) -> list[dict]:
        with self._lock:
            return [e for e in self.events if e.get("requestId") == channel_req_id]

    def snapshot(self) -> list[dict]:
        """Return a thread-safe copy of all collected events.

        Use this whenever you need to iterate over every event (rather than
        events for a single message hash). Iterating `self.events` directly is
        unsafe because `event_callback` appends from the wrapper's event
        thread.
        """
        with self._lock:
            return list(self.events)


def is_propagated_event(event: dict) -> bool:
    return event.get("eventType") == EVENT_PROPAGATED


def is_sent_event(event: dict) -> bool:
    return event.get("eventType") == EVENT_SENT


def is_error_event(event: dict) -> bool:
    return event.get("eventType") == EVENT_ERROR


def is_channel_error_event(event: dict) -> bool:
    return event.get("eventType") == EVENT_CHANNEL_ERROR


def wait_for_event(
    collector: EventCollector,
    message_hash: str,
    predicate,
    timeout_s: float,
    poll_interval_s: float = 0.5,
) -> Optional[dict]:
    """Poll until an event matching `predicate` arrives for `message_hash`,
    or until `timeout_s` elapses.  Returns the matching event or None.
    """
    return _wait_for(lambda: collector.get_events_for_message(message_hash), predicate, timeout_s, poll_interval_s)


def wait_for_channel_event(
    collector: EventCollector,
    channel_req_id: str,
    predicate,
    timeout_s: float,
    poll_interval_s: float = 0.5,
) -> Optional[dict]:
    """Like wait_for_event, for channel events, which carry the channel request id."""
    return _wait_for(lambda: collector.get_events_for_channel_request(channel_req_id), predicate, timeout_s, poll_interval_s)


def _wait_for(get_events, predicate, timeout_s: float, poll_interval_s: float) -> Optional[dict]:
    deadline = time.monotonic() + timeout_s

    while True:
        for event in get_events():
            if predicate(event):
                return event
        if time.monotonic() >= deadline:
            return None
        time.sleep(poll_interval_s)


def wait_for_propagated(collector: EventCollector, message_hash: str, timeout_s: float) -> Optional[dict]:
    return wait_for_event(collector, message_hash, is_propagated_event, timeout_s)


def wait_for_sent(collector: EventCollector, message_hash: str, timeout_s: float) -> Optional[dict]:
    return wait_for_event(collector, message_hash, is_sent_event, timeout_s)


def wait_for_error(collector: EventCollector, message_hash: str, timeout_s: float) -> Optional[dict]:
    return wait_for_event(collector, message_hash, is_error_event, timeout_s)


def assert_no_error(collector: EventCollector, message_hash: str, context: str = "") -> None:
    """Assert that no message_error event is currently buffered for `message_hash`."""
    event = wait_for_error(collector, message_hash, timeout_s=0)
    suffix = f" ({context})" if context else ""
    assert event is None, f"Unexpected message_error event{suffix}: {event}"


def wait_for_connected(
    collector: EventCollector,
    timeout_s: float = 10.0,
    poll_interval_s: float = 0.3,
) -> Optional[dict]:
    """Wait until a connection_status_change event with PartiallyConnected or Connected arrives."""
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        for event in collector.snapshot():
            if event.get("eventType") == "connection_status_change" and event.get("connectionStatus") in ("PartiallyConnected", "Connected"):
                return event
        time.sleep(poll_interval_s)
    return None


def wait_for_mesh(
    collector: EventCollector,
    timeout_s: float = 10.0,
    poll_interval_s: float = 0.3,
) -> bool:
    """Wait until the node's latest relay_topic_health_change for a shard says its mesh has a peer."""
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        latest_health = {}
        for event in collector.snapshot():
            if event.get("eventType") == EVENT_TOPIC_HEALTH_CHANGE:
                latest_health[event.get("pubsubTopic")] = event.get("topicHealth")
        if any(health in MESH_TOPIC_HEALTH for health in latest_health.values()):
            return True
        time.sleep(poll_interval_s)
    return False


TERMINAL_EVENT_TYPES = {EVENT_PROPAGATED, EVENT_SENT, EVENT_ERROR}


def assert_message_hash(send_result) -> str:
    """Assert that send() returned Ok with a 0x lowercase hex message hash, and return it."""
    assert send_result.is_ok(), f"send() must return Ok(messageHash), got: {send_result.err()}"
    message_hash = send_result.ok_value
    assert MESSAGE_HASH_RE.fullmatch(message_hash or ""), f"send() returned a malformed message hash: {message_hash!r}"
    return message_hash


def assert_send_refused(send_result, kind: str) -> str:
    """Assert that send() was refused with `kind`, the SendErrorKind at the end of the error text."""
    assert send_result.is_err(), f"send() must be refused with {kind}, got Ok({send_result.ok_value!r})"
    error = send_result.err()
    # The binding prefixes the FFI text with its own "send_message: callback failed" context.
    assert "Send failed: " in error, f"unexpected send() error text: {error!r}"
    assert error.endswith(f"({kind})"), f"send() must be refused with {kind}, got: {error!r}"
    return error


def send_once_connected(node, message: dict, timeout_s: float = 10.0, poll_interval_s: float = 0.5):
    """Send `message`, retrying while send() is refused with NotConnected (the node has no peer yet).

    For a node whose connection status may stay Disconnected though it has a peer,
    e.g. an edge without a filter peer, so wait_for_connected cannot gate the send.
    Returns the result of the last send() call.
    """
    deadline = time.monotonic() + timeout_s
    while True:
        send_result = node.send_message(message=message)
        refused_not_connected = send_result.is_err() and send_result.err().endswith(f"({SEND_REFUSED_NOT_CONNECTED})")
        if not refused_not_connected or time.monotonic() >= deadline:
            return send_result
        time.sleep(poll_interval_s)


def assert_no_message_events(collector: EventCollector, observation_s: float = 0.0) -> None:
    """Assert that no message_* event arrives within `observation_s`: a refused send gets no event."""
    if observation_s > 0:
        time.sleep(observation_s)
    events = [e for e in collector.snapshot() if e.get("eventType") in TERMINAL_EVENT_TYPES]
    assert not events, f"A refused send must get no message event, got: {events}"


def assert_event_invariants(collector: EventCollector, message_hash: str) -> None:
    """Check per-message event invariants (issue #163):
    - All events carry the correct messageHash.
    - No duplicate terminal events (Propagated, Sent, Error).
    - Sent never appears before Propagated.
    """
    events = collector.get_events_for_message(message_hash)
    assert events, f"No events found for message {message_hash}"

    counts: dict[str, int] = {}
    first_index: dict[str, int] = {}
    for i, event in enumerate(events):
        assert event.get("messageHash") == message_hash, (
            f"Event at index {i} has wrong messageHash: " f"expected {message_hash!r}, got {event.get('messageHash')!r}"
        )
        event_type = event.get("eventType", "")
        if event_type in TERMINAL_EVENT_TYPES:
            counts[event_type] = counts.get(event_type, 0) + 1
            if event_type not in first_index:
                first_index[event_type] = i

    for event_type, count in counts.items():
        assert count == 1, f"Duplicate {event_type} events for message {message_hash}: " f"got {count}, expected 1. Events: {events}"

    if EVENT_SENT in first_index and EVENT_PROPAGATED in first_index:
        assert first_index[EVENT_PROPAGATED] < first_index[EVENT_SENT], (
            f"message_sent (index {first_index[EVENT_SENT]}) arrived before "
            f"message_propagated (index {first_index[EVENT_PROPAGATED]}) "
            f"for message {message_hash}. Events: {events}"
        )


def get_node_multiaddr(node) -> str:
    """Return the TCP multiaddr (with peer-id) from a WrapperManager node.

    Multiaddrs is comma-separated and also lists the QUIC address when
    QUIC is enabled. Asserts that exactly one TCP address is present, so a
    malformed or ambiguous answer fails loudly instead of silently passing a
    bad string downstream to staticnodes / add_peers.
    """
    result = node.get_node_info("Multiaddrs")
    if result.is_err():
        raise RuntimeError(f"get_node_info failed: {result.err()}")

    raw = result.ok_value.strip()
    addrs = [a.strip() for a in raw.split(",") if a.strip()]
    if not addrs or not all(a.startswith("/") for a in addrs):
        raise RuntimeError(f"Unexpected multiaddr format: {raw!r}")

    tcp_addrs = [a for a in addrs if "/tcp/" in a and "/ws" not in a]
    if len(tcp_addrs) != 1:
        raise AssertionError(f"Expected a single TCP multiaddr from Multiaddrs, got: {raw!r}")

    return tcp_addrs[0]


# Matches the /tcp/<port>/ segment in a libp2p multiaddr.
TCP_PORT_RE = re.compile(r"/tcp/(\d+)/")


def get_node_tcp_port(node) -> int:
    """Return the TCP port the node advertises in its multiaddr."""
    multiaddr = get_node_multiaddr(node)
    match = TCP_PORT_RE.search(multiaddr)
    if not match:
        raise RuntimeError(f"multiaddr missing /tcp/<port>/ segment: {multiaddr!r}")
    return int(match.group(1))


def get_node_bound_ports(node) -> dict:
    """Return the MyBoundPorts debug info .

    Keys: tcp, webSocket, quic, rest, discv5Udp, metrics. A value of 0 means the
    service is disabled or did not bind.
    """
    result = node.get_node_info("MyBoundPorts")
    if result.is_err():
        raise RuntimeError(f"MyBoundPorts query failed: {result.err()}")
    return json.loads(result.ok_value)


def enr_udp_port(enr_uri: str) -> int:
    """Extract the advertised udp port from a text-encoded ENR.

    An ENR is "enr:" + base64url(RLP). Instead of pulling in a full RLP
    decoder, find the "udp" key in the raw bytes and read the value after it.
    """
    if not enr_uri.startswith("enr:"):
        raise RuntimeError(f"not an ENR URI: {enr_uri!r}")
    b64 = enr_uri[len("enr:") :]
    payload = base64.urlsafe_b64decode(b64 + "=" * (-len(b64) % 4))

    key = payload.find(b"\x83udp")  # "udp" encoded as a 3-byte RLP string
    if key == -1:
        raise RuntimeError(f"ENR has no udp entry: {enr_uri!r}")

    prefix = payload[key + 4]
    if prefix < 0x80:  # values < 128 are encoded as a single byte
        return prefix
    size = prefix - 0x80  # short string: prefix is 0x80 + length
    return int.from_bytes(payload[key + 5 : key + 5 + size], "big")


def unique_channel_id(prefix: str) -> str:
    """A per-run channel id.

    SDS state is persisted per channelId and restored on create, so a fixed id
    leaks one run's causal history into the next.
    """
    return f"{prefix}-{uuid.uuid4().hex[:8]}"


def local_storage_config() -> dict:
    """Storage paths in a fresh directory, so no two nodes share SQLite files."""
    storage_dir = tempfile.mkdtemp(prefix="c_abi_node_")
    return {
        "localStoragePath": storage_dir,
        "storeMessageDbUrl": f"sqlite://{os.path.join(storage_dir, 'store.sqlite3')}",
    }


def create_message_bindings(**overrides) -> dict:
    envelope = {
        "contentTopic": DEFAULT_CONTENT_TOPIC,
        "payload": DEFAULT_PAYLOAD,
        "ephemeral": False,
    }
    envelope.update(overrides)
    return envelope
