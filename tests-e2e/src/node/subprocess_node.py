from __future__ import annotations

import multiprocessing as mp
import os
import queue
import tempfile

from src.libs.common import delay
from src.node.wrapper_helpers import EventCollector, create_message_bindings, wait_for_connected
from src.node.wrappers_manager import WrapperManager

# `spawn`, not `fork`: the child loads its own liblogosdelivery.
_SPAWN = mp.get_context("spawn")

SENDER_READY_TIMEOUT_S = 120.0
SENDER_STOP_TIMEOUT_S = 30.0


def _sender_worker(config, content_topic, channel_id, sender_id, payload_b64, settle_s, result_q, stop_evt):
    # A private cwd so the library's default "./data" store is not the parent node's.
    os.chdir(tempfile.mkdtemp(prefix="rc_sender_"))

    collector = EventCollector()
    started = WrapperManager.create_and_start(config=config, event_cb=collector.event_callback)
    if started.is_err():
        result_q.put(f"sender start failed: {started.err()}")
        return

    with started.ok_value as sender:
        if wait_for_connected(collector) is None:
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

        send_result = sender.channel_send(channel_id, create_message_bindings(payload=payload_b64))
        if send_result.is_err():
            result_q.put(f"sender channel_send failed: {send_result.err()}")
            return
        if not send_result.ok_value:
            result_q.put(f"sender channel_send returned an empty handle: {send_result.ok_value!r}")
            return

        # Signal the message is on the wire, then stay alive so the relay
        # connection persists while it propagates to the receiver.
        result_q.put(None)
        stop_evt.wait()


class ChannelSenderProcess:
    """Run a channel sender node in a separate, storage-isolated process.

    `__enter__` starts the sender and blocks until the message is on the wire
    (raising on failure/timeout); `__exit__` tears it down. Needed because nodes
    sharing a storage path drop each other's channel messages as duplicates.
    """

    def __init__(self, config, *, content_topic, channel_id, sender_id, payload_b64, settle_s):
        self._args = (config, content_topic, channel_id, sender_id, payload_b64, settle_s)
        self._stop_evt = _SPAWN.Event()
        self._result_q = _SPAWN.Queue()
        self._proc = None

    def __enter__(self) -> "ChannelSenderProcess":
        self._proc = _SPAWN.Process(
            target=_sender_worker,
            args=(*self._args, self._result_q, self._stop_evt),
            daemon=True,
        )
        self._proc.start()
        try:
            outcome = self._result_q.get(timeout=SENDER_READY_TIMEOUT_S)
        except queue.Empty:
            self.__exit__(None, None, None)
            raise AssertionError(f"sender subprocess did not report readiness within {SENDER_READY_TIMEOUT_S}s")
        if outcome is not None:
            self.__exit__(None, None, None)
            raise AssertionError(outcome)
        return self

    def __exit__(self, *_) -> None:
        self._stop_evt.set()
        if self._proc is not None:
            self._proc.join(timeout=SENDER_STOP_TIMEOUT_S)
            if self._proc.is_alive():
                self._proc.terminate()
                self._proc.join()
            self._proc = None
