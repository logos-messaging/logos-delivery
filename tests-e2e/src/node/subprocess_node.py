from __future__ import annotations

import multiprocessing as mp
import os
import queue
import tempfile
import time

from src.libs.common import delay
from src.node.wrapper_helpers import EVENT_CHANNEL_RECEIVED, EventCollector, create_message_bindings, get_node_multiaddr, wait_for_connected
from src.node.wrappers_manager import WrapperManager

# `spawn`, not `fork`: the child loads its own liblogosdelivery.
_SPAWN = mp.get_context("spawn")

SENDER_READY_TIMEOUT_S = 120.0
SENDER_STOP_TIMEOUT_S = 30.0
SEND_ACK_TIMEOUT_S = 60.0
_SERVE_POLL_S = 0.2

CMD_SEND = "send"
CMD_RECREATE = "recreate"


def _send(sender, channel_id, payload_b64):
    """Sends on the channel; returns None on success, an error string otherwise."""
    send_result = sender.channel_send(channel_id, create_message_bindings(payload=payload_b64))
    if send_result.is_err():
        return f"sender channel_send failed: {send_result.err()}"
    if not send_result.ok_value:
        return f"sender channel_send returned an empty handle: {send_result.ok_value!r}"
    return None


def _recreate(sender, channel_id, content_topic, sender_id):
    """Closes the channel and creates it again under the same id."""
    close_result = sender.channel_close(channel_id)
    if close_result.is_err():
        return f"sender channel_close failed: {close_result.err()}"

    create_result = sender.channel_create(channel_id, content_topic, sender_id)
    if create_result.is_err():
        return f"sender channel_create failed: {create_result.err()}"
    return None


def _sender_worker(config, content_topic, channel_id, sender_id, payload_b64, settle_s, result_q, cmd_q, evt_q, stop_evt):
    # A private cwd so the library's default "./data" store is not the parent node's.
    os.chdir(tempfile.mkdtemp(prefix="rc_sender_"))

    collector = EventCollector()
    started = WrapperManager.create_and_start(config=config, event_cb=collector.event_callback)
    if started.is_err():
        result_q.put(f"sender start failed: {started.err()}")
        return

    with started.ok_value as sender:
        # No staticnodes: this peer is first up, the node under test dials it later.
        if config.get("staticnodes") and wait_for_connected(collector) is None:
            result_q.put("sender did not reach Connected/PartiallyConnected state")
            return

        subscribe_result = sender.subscribe_content_topic(content_topic)
        if subscribe_result.is_err():
            result_q.put(f"sender subscribe_content_topic failed: {subscribe_result.err()}")
            return

        create_result = sender.channel_create(channel_id, content_topic, sender_id)
        if create_result.is_err():
            result_q.put(f"sender channel_create failed: {create_result.err()}")
            return

        delay(settle_s)

        if payload_b64 is not None:
            outcome = _send(sender, channel_id, payload_b64)
            if outcome is not None:
                result_q.put(outcome)
                return

        # Signal readiness, then stay alive so the relay connection persists
        # while messages propagate and SDS answers repair requests.
        result_q.put({"multiaddr": get_node_multiaddr(sender)})

        forwarded = 0
        while not stop_evt.is_set():
            received = [e for e in collector.snapshot() if e.get("eventType") == EVENT_CHANNEL_RECEIVED and e.get("channelId") == channel_id]
            for event in received[forwarded:]:
                evt_q.put(event)
            forwarded = len(received)

            try:
                op, arg = cmd_q.get(timeout=_SERVE_POLL_S)
            except queue.Empty:
                continue

            if op == CMD_SEND:
                result_q.put(_send(sender, channel_id, arg))
                continue

            outcome = _recreate(sender, channel_id, content_topic, sender_id)
            if outcome is None:
                # channel_close drops the content topic subscription and
                # channel_create re-adds it; let the mesh catch up before the
                # next send, or it goes out to nobody.
                delay(settle_s)
            result_q.put(outcome)


class ChannelSenderProcess:
    """Run a channel peer node in a separate, storage-isolated process.

    `__enter__` blocks until the peer is ready, including its initial
    `payload_b64` send when given; `__exit__` tears it down. Needed because nodes
    sharing a storage path drop each other's channel messages as duplicates.

    `multiaddr` lets the node under test dial this peer, `send()` drives further
    sends, `close_and_recreate()` cycles the channel under the same id, and
    `wait_for_received()` reports what this peer received.
    """

    def __init__(self, config, *, content_topic, channel_id, sender_id, payload_b64=None, settle_s):
        self._args = (config, content_topic, channel_id, sender_id, payload_b64, settle_s)
        self._stop_evt = _SPAWN.Event()
        self._result_q = _SPAWN.Queue()
        self._cmd_q = _SPAWN.Queue()
        self._evt_q = _SPAWN.Queue()
        self._proc = None
        self._received = []
        self.multiaddr = None

    def __enter__(self) -> "ChannelSenderProcess":
        self._proc = _SPAWN.Process(
            target=_sender_worker,
            args=(*self._args, self._result_q, self._cmd_q, self._evt_q, self._stop_evt),
            daemon=True,
        )
        self._proc.start()
        try:
            outcome = self._result_q.get(timeout=SENDER_READY_TIMEOUT_S)
        except queue.Empty:
            self.__exit__(None, None, None)
            raise AssertionError(f"sender subprocess did not report readiness within {SENDER_READY_TIMEOUT_S}s")
        if not isinstance(outcome, dict):
            self.__exit__(None, None, None)
            raise AssertionError(outcome)
        self.multiaddr = outcome["multiaddr"]
        return self

    def _run(self, op, arg, what) -> None:
        self._cmd_q.put((op, arg))
        try:
            outcome = self._result_q.get(timeout=SEND_ACK_TIMEOUT_S)
        except queue.Empty:
            raise AssertionError(f"sender subprocess did not acknowledge {what} within {SEND_ACK_TIMEOUT_S}s")
        if outcome is not None:
            raise AssertionError(outcome)

    def send(self, payload_b64) -> None:
        """Sends another message on the channel, blocking until the peer acks it."""
        self._run(CMD_SEND, payload_b64, "a send")

    def close_and_recreate(self) -> None:
        """Closes and re-creates the channel under the same id, blocking until
        the peer has re-subscribed and the mesh has settled."""
        self._run(CMD_RECREATE, None, "a close/re-create")

    def wait_for_received(self, count, timeout_s) -> list:
        """Channel messages this peer received, oldest first; waits for `count`."""
        deadline = time.monotonic() + timeout_s
        while len(self._received) < count and time.monotonic() < deadline:
            try:
                self._received.append(self._evt_q.get(timeout=_SERVE_POLL_S))
            except queue.Empty:
                continue
        return list(self._received)

    def __exit__(self, *_) -> None:
        self._stop_evt.set()
        if self._proc is not None:
            self._proc.join(timeout=SENDER_STOP_TIMEOUT_S)
            if self._proc.is_alive():
                self._proc.terminate()
                self._proc.join()
            self._proc = None
