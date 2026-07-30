import json
import threading

from cffi import FFI
from pathlib import Path
from result import Result, Ok, Err

ffi = FFI()

ffi.cdef(
    """
typedef void (*FFICallBack)(int callerRet, const char *msg, size_t len, void *userData);

void *logosdelivery_create_node(
    const char *configJson,
    FFICallBack callback,
    void *userData
);

int logosdelivery_start_node(
    void *ctx,
    FFICallBack callback,
    void *userData
);

int logosdelivery_stop_node(
    void *ctx,
    FFICallBack callback,
    void *userData
);

uint64_t logosdelivery_add_event_listener(
    void *ctx,
    const char *eventName,
    FFICallBack callback,
    void *userData
);

int logosdelivery_remove_event_listener(
    void *ctx,
    uint64_t listenerId
);

int logosdelivery_destroy(
    void *ctx,
    FFICallBack callback,
    void *userData
);

int logosdelivery_subscribe(
    void *ctx,
    FFICallBack callback,
    void *userData,
    const char *contentTopic
);

int logosdelivery_unsubscribe(
    void *ctx,
    FFICallBack callback,
    void *userData,
    const char *contentTopic
);

int logosdelivery_send(
    void *ctx,
    FFICallBack callback,
    void *userData,
    const char *messageJson
);

int logosdelivery_get_available_node_info_ids(
    void *ctx,
    FFICallBack callback,
    void *userData
);

int logosdelivery_get_node_info(
    void *ctx,
    FFICallBack callback,
    void *userData,
    const char *nodeInfoId
);

int logosdelivery_get_available_configs(
    void *ctx,
    FFICallBack callback,
    void *userData
);
"""
)

_repo_root = Path(__file__).resolve().parents[1]
lib = ffi.dlopen(str(_repo_root / "lib" / "liblogosdelivery.so"))

CallbackType = ffi.callback("void(int, const char*, size_t, void*)")

RET_OK = 0

# Non-terminal progress tick. It fires every ~5s while a request is still in
# flight and is always followed by a terminal RET_OK/RET_ERR, so a caller that
# latched it would fail every call slower than five seconds -- start_node most
# of all, since it boots the node and joins the network.
RET_STALE_WARN = 3

# Since 0.3.0 a listener is registered per event name, so a caller that wants
# every event registers once per name.
EVENT_NAMES = (
    "onMessageSent",
    "onMessageError",
    "onMessagePropagated",
    "onMessageReceived",
    "onConnectionStatusChange",
    "onTopicHealthChange",
    "onConnectionChange",
    "onReceivedMessage",
    "onChannelMessageReceived",
    "onChannelMessageSent",
    "onChannelMessageError",
)

_CBOR_MAJOR_BYTES = 2
_CBOR_MAJOR_TEXT = 3

# The event thread calls these from outside Python. cffi frees the trampoline
# when the object dies, so a late event would land on freed memory; keep every
# event callback alive for the whole process.
_PINNED_EVENT_CALLBACKS = []


def _decode_cbor_string(raw: bytes) -> bytes:
    """Unwrap a CBOR definite-length text/byte string.

    Since 0.3.0 the library encodes every RET_OK reply payload with CBOR. Error
    payloads and the RET_STALE_WARN tick stay plain, and so do event payloads.
    """
    if not raw:
        return b""

    header = raw[0]
    if header >> 5 not in (_CBOR_MAJOR_BYTES, _CBOR_MAJOR_TEXT):
        raise ValueError(f"reply is not a CBOR string: header {header:#04x}")

    info = header & 0x1F
    if info < 24:
        length, offset = info, 1
    elif info <= 27:
        size = 1 << (info - 24)
        length, offset = int.from_bytes(raw[1 : 1 + size], "big"), 1 + size
    else:
        raise ValueError(f"unsupported CBOR string header: {header:#04x}")

    payload = raw[offset : offset + length]
    if len(payload) != length:
        raise ValueError(f"truncated CBOR string: want {length} bytes, got {len(payload)}")

    return payload


def _new_cb_state():
    return {
        "done": threading.Event(),
        "ret": None,
        "msg": b"",
    }


def _wait_cb_raw(
    state,
    op_name: str,
    timeout_s: float = 20.0,
) -> Result[tuple[int, bytes], str]:
    ok = state["done"].wait(timeout_s)
    if not ok:
        return Err(f"{op_name}: timeout after {timeout_s}s")

    cb_ret = state["ret"]
    if cb_ret is None:
        return Err(f"{op_name}: callback ret is None")

    if cb_ret != RET_OK:
        return Ok((cb_ret, state["msg"]))

    try:
        return Ok((cb_ret, _decode_cbor_string(state["msg"])))
    except ValueError as e:
        return Err(f"{op_name}: {e}")


def _wait_cb_ok(state, op_name: str, timeout_s: float = 20.0) -> Result[int, str]:
    wait_result = _wait_cb_raw(state, op_name, timeout_s)
    if wait_result.is_err():
        return Err(wait_result.err())

    cb_ret, cb_msg = wait_result.ok_value
    if cb_ret != 0:
        return Err(f"callback failed in _wait_cb_ok: {op_name} (ret={cb_ret}) msg={cb_msg!r}")

    return Ok(cb_ret)


class NodeWrapper:
    def __init__(self, ctx, config_buffer, event_cb_handler, listener_ids=()):
        self.ctx = ctx
        self._config_buffer = config_buffer
        self._event_cb_handler = event_cb_handler
        self._listener_ids = tuple(listener_ids)

    @staticmethod
    def _make_waiting_cb(state):
        def c_cb(ret, char_p, length, userData):
            if int(ret) == RET_STALE_WARN:
                return

            msg = ffi.buffer(char_p, length)[:] if char_p != ffi.NULL else b""

            if not state["done"].is_set():
                state["ret"] = int(ret)
                state["msg"] = msg
                state["done"].set()

        return CallbackType(c_cb)

    @staticmethod
    def _make_event_cb(py_callback):
        def c_cb(ret, char_p, length, userData):
            msg = ffi.buffer(char_p, length)[:] if char_p != ffi.NULL else b""
            py_callback(int(ret), msg)

        handler = CallbackType(c_cb)
        _PINNED_EVENT_CALLBACKS.append(handler)
        return handler

    @classmethod
    def create_node(
        cls,
        config: dict,
        event_cb=None,
        *,
        timeout_s: float = 20.0,
    ) -> Result["NodeWrapper", str]:
        config_json = json.dumps(config, separators=(",", ":"), ensure_ascii=False)
        config_buffer = ffi.new("char[]", config_json.encode("utf-8"))

        state = _new_cb_state()
        cb = cls._make_waiting_cb(state)

        ctx = lib.logosdelivery_create_node(
            config_buffer,
            cb,
            ffi.NULL,
        )

        if ctx == ffi.NULL:
            return Err("create_node: ctx is NULL")

        node = cls(ctx, config_buffer, None)

        wait_result = _wait_cb_ok(state, "create_node", timeout_s)
        if wait_result.is_err():
            node.destroy()
            return Err(wait_result.err())

        if event_cb is None:
            return Ok(node)

        node._event_cb_handler = cls._make_event_cb(event_cb)
        for event_name in EVENT_NAMES:
            listener_id = lib.logosdelivery_add_event_listener(
                ctx,
                event_name.encode("utf-8"),
                node._event_cb_handler,
                ffi.NULL,
            )
            if listener_id == 0:
                node.destroy()
                return Err(f"create_node: add_event_listener({event_name}) failed")
            node._listener_ids += (listener_id,)

        return Ok(node)

    @classmethod
    def create_and_start(
        cls,
        config: dict,
        event_cb=None,
        *,
        timeout_s: float = 20.0,
    ) -> Result["NodeWrapper", str]:
        node_result = cls.create_node(
            config=config,
            event_cb=event_cb,
            timeout_s=timeout_s,
        )
        if node_result.is_err():
            return Err(node_result.err())

        node = node_result.ok_value

        start_result = node.start_node(timeout_s=timeout_s)
        if start_result.is_err():
            # The caller drops the node here, so tear it down before its
            # callbacks outlive the wrapper that owns them.
            node.destroy(timeout_s=timeout_s)
            return Err(start_result.err())

        return Ok(node)

    def start_node(self, *, timeout_s: float = 20.0) -> Result[int, str]:
        state = _new_cb_state()
        cb = self._make_waiting_cb(state)

        rc = lib.logosdelivery_start_node(self.ctx, cb, ffi.NULL)
        if rc != 0:
            return Err(f"start_node: immediate call failed (ret={rc})")

        return _wait_cb_ok(state, "start_node", timeout_s)

    def stop_node(self, *, timeout_s: float = 20.0) -> Result[int, str]:
        state = _new_cb_state()
        cb = self._make_waiting_cb(state)

        rc = lib.logosdelivery_stop_node(self.ctx, cb, ffi.NULL)
        if rc != 0:
            return Err(f"stop_node: immediate call failed (ret={rc})")

        return _wait_cb_ok(state, "stop_node", timeout_s)

    def destroy(self, *, timeout_s: float = 20.0) -> Result[int, str]:
        if self.ctx == ffi.NULL:
            return Ok(RET_OK)

        # Drop the listeners first so the event thread cannot reach the Python
        # callback once the context is gone.
        for listener_id in self._listener_ids:
            lib.logosdelivery_remove_event_listener(self.ctx, listener_id)
        self._listener_ids = ()

        state = _new_cb_state()
        cb = self._make_waiting_cb(state)

        rc = lib.logosdelivery_destroy(self.ctx, cb, ffi.NULL)
        if rc != 0:
            return Err(f"destroy: immediate call failed (ret={rc})")

        wait_result = _wait_cb_ok(state, "destroy", timeout_s)
        if wait_result.is_err():
            return Err(wait_result.err())

        self.ctx = ffi.NULL
        return wait_result

    def stop_and_destroy(self, *, timeout_s: float = 20.0) -> Result[int, str]:
        stop_result = self.stop_node(timeout_s=timeout_s)

        # Destroy even when the stop fails: a node that keeps its context alive
        # also keeps calling back into a wrapper the caller is about to drop.
        destroy_result = self.destroy(timeout_s=timeout_s)

        if stop_result.is_err():
            return Err(stop_result.err())

        return destroy_result

    def subscribe_content_topic(self, content_topic: str, *, timeout_s: float = 20.0) -> Result[int, str]:
        state = _new_cb_state()
        cb = self._make_waiting_cb(state)

        rc = lib.logosdelivery_subscribe(
            self.ctx,
            cb,
            ffi.NULL,
            content_topic.encode("utf-8"),
        )
        if rc != 0:
            return Err(f"subscribe_content_topic: immediate call failed (ret={rc})")

        return _wait_cb_ok(state, f"subscribe({content_topic})", timeout_s)

    def unsubscribe_content_topic(self, content_topic: str, *, timeout_s: float = 20.0) -> Result[int, str]:
        state = _new_cb_state()
        cb = self._make_waiting_cb(state)

        rc = lib.logosdelivery_unsubscribe(
            self.ctx,
            cb,
            ffi.NULL,
            content_topic.encode("utf-8"),
        )
        if rc != 0:
            return Err(f"unsubscribe_content_topic: immediate call failed (ret={rc})")

        return _wait_cb_ok(state, f"unsubscribe({content_topic})", timeout_s)

    def send_message(self, message: dict, *, timeout_s: float = 20.0) -> Result[str, str]:
        state = _new_cb_state()
        cb = self._make_waiting_cb(state)

        message_json = json.dumps(message, separators=(",", ":"), ensure_ascii=False)

        rc = lib.logosdelivery_send(
            self.ctx,
            cb,
            ffi.NULL,
            message_json.encode("utf-8"),
        )
        if rc != 0:
            return Err(f"send_message: immediate call failed (ret={rc})")

        wait_result = _wait_cb_raw(state, "send_message", timeout_s)
        if wait_result.is_err():
            return Err(wait_result.err())

        cb_ret, cb_msg = wait_result.ok_value
        if cb_ret != 0:
            return Err(f"send_message: callback failed (ret={cb_ret}) msg={cb_msg!r}")

        request_id = cb_msg.decode("utf-8") if cb_msg else ""
        return Ok(request_id)

    def get_available_node_info_ids(self, *, timeout_s: float = 20.0) -> Result[list[str], str]:
        state = _new_cb_state()
        cb = self._make_waiting_cb(state)

        rc = lib.logosdelivery_get_available_node_info_ids(self.ctx, cb, ffi.NULL)
        if rc != 0:
            return Err(f"get_available_node_info_ids: immediate call failed (ret={rc})")

        wait_result = _wait_cb_raw(state, "get_available_node_info_ids", timeout_s)
        if wait_result.is_err():
            return Err(wait_result.err())

        cb_ret, cb_msg = wait_result.ok_value
        if cb_ret != 0:
            return Err(f"get_available_node_info_ids: callback failed (ret={cb_ret})")
        if not cb_msg:
            return Err("get_available_node_info_ids: empty response")

        try:
            return Ok(json.loads(cb_msg.decode("utf-8").strip().lstrip("@")))
        except Exception as e:
            return Err(f"get_available_node_info_ids: invalid response: {e}")

    def get_node_info(self, node_info_id: str, *, timeout_s: float = 20.0) -> Result[dict, str]:
        state = _new_cb_state()
        cb = self._make_waiting_cb(state)

        rc = lib.logosdelivery_get_node_info(
            self.ctx,
            cb,
            ffi.NULL,
            node_info_id.encode("utf-8"),
        )
        if rc != 0:
            return Err(f"get_node_info: immediate call failed (ret={rc})")

        wait_result = _wait_cb_raw(state, "get_node_info", timeout_s)
        if wait_result.is_err():
            return Err(wait_result.err())

        cb_ret, cb_msg = wait_result.ok_value
        if cb_ret != 0:
            return Err(f"get_node_info: callback failed (ret={cb_ret}) msg={cb_msg!r}")

        if not cb_msg:
            return Err("get_node_info: empty response")

        try:
            result = json.loads(cb_msg.decode("utf-8"))
        except Exception as e:
            return Err(f"get_node_info: invalid json: {e}")

        return Ok(result)

    def get_available_configs(self, *, timeout_s: float = 20.0) -> Result[dict, str]:
        state = _new_cb_state()
        cb = self._make_waiting_cb(state)

        rc = lib.logosdelivery_get_available_configs(self.ctx, cb, ffi.NULL)
        if rc != 0:
            return Err(f"get_available_configs: immediate call failed (ret={rc})")

        wait_result = _wait_cb_raw(state, "get_available_configs", timeout_s)
        if wait_result.is_err():
            return Err(wait_result.err())

        cb_ret, cb_msg = wait_result.ok_value
        if cb_ret != 0:
            return Err(f"get_available_configs: callback failed (ret={cb_ret}) msg={cb_msg!r}")

        if not cb_msg:
            return Err("get_available_configs: empty response")

        try:
            result = json.loads(cb_msg.decode("utf-8"))
        except Exception as e:
            return Err(f"get_available_configs: invalid json: {e}")

        return Ok(result)

