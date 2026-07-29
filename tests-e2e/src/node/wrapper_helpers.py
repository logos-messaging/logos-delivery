from __future__ import annotations

import base64
import json
import re
import threading
import time
from typing import Optional
from src.libs.common import to_base64

DEFAULT_CONTENT_TOPIC = "/test/1/default/proto"
DEFAULT_PAYLOAD = to_base64("test payload")
EVENT_PROPAGATED = "message_propagated"
EVENT_SENT = "message_sent"
EVENT_ERROR = "message_error"

# MaxTimeInCache from send_service.nim.
MAX_TIME_IN_CACHE_S = 60.0
# Extra slack to cover the background retry loop tick after the window expires.
CACHE_EXPIRY_SLACK_S = 10.0
ERROR_AFTER_CACHE_EXPIRY_TIMEOUT_S = MAX_TIME_IN_CACHE_S + CACHE_EXPIRY_SLACK_S
RETRY_WINDOW_EXPIRED_MSG = "Unable to send within retry time window"


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

    def get_events_for_request(self, request_id: str) -> list[dict]:
        with self._lock:
            return [e for e in self.events if e.get("requestId") == request_id]

    def snapshot(self) -> list[dict]:
        """Return a thread-safe copy of all collected events.

        Use this whenever you need to iterate over every event (rather than
        events for a single request_id). Iterating `self.events` directly is
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


def wait_for_event(
    collector: EventCollector,
    request_id: str,
    predicate,
    timeout_s: float,
    poll_interval_s: float = 0.5,
) -> Optional[dict]:
    """Poll until an event matching `predicate` arrives for `request_id`,
    or until `timeout_s` elapses.  Returns the matching event or None.
    """
    deadline = time.monotonic() + timeout_s

    while True:
        for event in collector.get_events_for_request(request_id):
            if predicate(event):
                return event
        if time.monotonic() >= deadline:
            return None
        time.sleep(poll_interval_s)


def wait_for_propagated(collector: EventCollector, request_id: str, timeout_s: float) -> Optional[dict]:
    return wait_for_event(collector, request_id, is_propagated_event, timeout_s)


def wait_for_sent(collector: EventCollector, request_id: str, timeout_s: float) -> Optional[dict]:
    return wait_for_event(collector, request_id, is_sent_event, timeout_s)


def wait_for_error(collector: EventCollector, request_id: str, timeout_s: float) -> Optional[dict]:
    return wait_for_event(collector, request_id, is_error_event, timeout_s)


def assert_no_error(collector: EventCollector, request_id: str, context: str = "") -> None:
    """Assert that no message_error event is currently buffered for `request_id`."""
    event = wait_for_error(collector, request_id, timeout_s=0)
    suffix = f" ({context})" if context else ""
    assert event is None, f"Unexpected message_error event{suffix}: {event}"


def assert_no_sent(collector: EventCollector, request_id: str, context: str = "") -> None:
    """Assert that no message_sent event is currently buffered for `request_id`."""
    event = wait_for_sent(collector, request_id, timeout_s=0)
    suffix = f" ({context})" if context else ""
    assert event is None, f"Unexpected message_sent event{suffix}: {event}"


def assert_no_propagated(collector: EventCollector, request_id: str, context: str = "") -> None:
    """Assert that no message_propagated event is currently buffered for `request_id`."""
    event = wait_for_propagated(collector, request_id, timeout_s=0)
    suffix = f" ({context})" if context else ""
    assert event is None, f"Unexpected message_propagated event{suffix}: {event}"


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


TERMINAL_EVENT_TYPES = {EVENT_PROPAGATED, EVENT_SENT, EVENT_ERROR}


def assert_event_invariants(collector: EventCollector, request_id: str) -> None:
    """Check per-request event invariants (issue #163):
    - All events carry the correct requestId.
    - No duplicate terminal events (Propagated, Sent, Error).
    - Sent never appears before Propagated.
    """
    events = collector.get_events_for_request(request_id)
    assert events, f"No events found for request {request_id}"

    counts: dict[str, int] = {}
    first_index: dict[str, int] = {}
    for i, event in enumerate(events):
        assert event.get("requestId") == request_id, (
            f"Event at index {i} has wrong requestId: " f"expected {request_id!r}, got {event.get('requestId')!r}"
        )
        event_type = event.get("eventType", "")
        if event_type in TERMINAL_EVENT_TYPES:
            counts[event_type] = counts.get(event_type, 0) + 1
            if event_type not in first_index:
                first_index[event_type] = i

    for event_type, count in counts.items():
        assert count == 1, f"Duplicate {event_type} events for request {request_id}: " f"got {count}, expected 1. Events: {events}"

    if EVENT_SENT in first_index and EVENT_PROPAGATED in first_index:
        assert first_index[EVENT_PROPAGATED] < first_index[EVENT_SENT], (
            f"message_sent (index {first_index[EVENT_SENT]}) arrived before "
            f"message_propagated (index {first_index[EVENT_PROPAGATED]}) "
            f"for request {request_id}. Events: {events}"
        )


def get_node_multiaddr(node) -> str:
    """Return the TCP multiaddr (with peer-id) from a WrapperManager node.

    Asserts that the wrapper returned exactly one address. If the wrapper ever
    starts returning multiple addresses (newline/comma-separated or a JSON
    list), this fails loudly instead of silently passing a malformed string
    downstream to staticnodes / add_peers.
    """
    result = node.get_node_info_raw("MyMultiaddresses")
    if result.is_err():
        raise RuntimeError(f"get_node_info_raw failed: {result.err()}")

    addr = result.ok_value.strip()
    if not addr or not addr.startswith("/"):
        raise RuntimeError(f"Unexpected multiaddr format: {addr!r}")

    if "\n" in addr or "," in addr or addr.startswith("["):
        raise AssertionError(f"Expected a single multiaddr from MyMultiaddresses, got multiple: {addr!r}")

    return addr


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

    Keys: tcp, webSocket, rest, discv5Udp, metrics. A value of 0 means the
    service is disabled or did not bind.
    """
    result = node.get_node_info_raw("MyBoundPorts")
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


def create_message_bindings(**overrides) -> dict:
    envelope = {
        "contentTopic": DEFAULT_CONTENT_TOPIC,
        "payload": DEFAULT_PAYLOAD,
        "ephemeral": False,
    }
    envelope.update(overrides)
    return envelope


def assert_no_unknown_request_ids(collector: EventCollector, issued_request_ids) -> None:
    """Cross-association guard: every event carrying a requestId must belong
    to one of the request ids we issued. Catches events that get attached to
    the wrong request id under concurrency.
    """
    issued = set(issued_request_ids)
    for event in collector.snapshot():
        event_request_id = event.get("requestId")
        if event_request_id is None:
            continue
        assert event_request_id in issued, f"Event carries an unknown requestId={event_request_id!r}, " f"not in issued set {issued}. Event: {event}"
