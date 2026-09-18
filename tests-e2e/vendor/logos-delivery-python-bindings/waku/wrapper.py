import json
import threading

import cbor2
from cffi import FFI
from pathlib import Path
from result import Result, Ok, Err

ffi = FFI()

ffi.cdef(
    """
typedef void (*FFICallback)(int callerRet, const char *msg, size_t len, void *userData);

void *logosdelivery_create_node(
    const uint8_t *reqCbor,
    size_t reqCborLen,
    FFICallback onCreated,
    void *userData
);

int logosdelivery_destroy(void *ctx);

int logosdelivery_start_node(void *ctx, FFICallback callback, void *userData, const uint8_t *reqCbor, size_t reqCborLen);
int logosdelivery_stop_node(void *ctx, FFICallback callback, void *userData, const uint8_t *reqCbor, size_t reqCborLen);
int logosdelivery_get_available_node_info_ids(void *ctx, FFICallback callback, void *userData, const uint8_t *reqCbor, size_t reqCborLen);
int logosdelivery_get_available_configs(void *ctx, FFICallback callback, void *userData, const uint8_t *reqCbor, size_t reqCborLen);

int logosdelivery_subscribe(void *ctx, FFICallback callback, void *userData, const uint8_t *reqCbor, size_t reqCborLen);
int logosdelivery_unsubscribe(void *ctx, FFICallback callback, void *userData, const uint8_t *reqCbor, size_t reqCborLen);
int logosdelivery_send(void *ctx, FFICallback callback, void *userData, const uint8_t *reqCbor, size_t reqCborLen);
int logosdelivery_get_node_info(void *ctx, FFICallback callback, void *userData, const uint8_t *reqCbor, size_t reqCborLen);

uint64_t logosdelivery_add_event_listener(
    void *ctx,
    const char *eventName,
    FFICallback callback,
    void *userData
);

int logosdelivery_remove_event_listener(
    void *ctx,
    uint64_t listenerId
);

int logosdelivery_channel_create(void *ctx, FFICallback callback, void *userData, const uint8_t *reqCbor, size_t reqCborLen);
int logosdelivery_channel_send(void *ctx, FFICallback callback, void *userData, const uint8_t *reqCbor, size_t reqCborLen);
int logosdelivery_channel_close(void *ctx, FFICallback callback, void *userData, const uint8_t *reqCbor, size_t reqCborLen);
"""
)

_repo_root = Path(__file__).resolve().parents[1]
lib = ffi.dlopen(str(_repo_root / "lib" / "liblogosdelivery.so"))

CallbackType = ffi.callback("void(int, const char*, size_t, void*)")

# Non-terminal progress tick (~every 5s while a request is in flight), always
# followed by a terminal RET_OK/RET_ERR. The waiting callbacks drop it so a slow
# call (start_node most of all) is not latched as a result.
RET_STALE_WARN = 3

# Every event the library emits. Since 0.3.0 a listener is registered per event
# name, so an `event_cb` that wants them all registers once per name.
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


def _encode_request(fields: dict):
    payload = cbor2.dumps(fields)
    return ffi.new("uint8_t[]", payload), len(payload)


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

    if state["ret"] is None:
        return Err(f"{op_name}: callback ret is None")

    return Ok((state["ret"], state["msg"]))


def _wait_cb_ok(state, op_name: str, timeout_s: float = 20.0) -> Result[int, str]:
    wait_result = _wait_cb_raw(state, op_name, timeout_s)
    if wait_result.is_err():
        return Err(wait_result.err())

    cb_ret, cb_msg = wait_result.ok_value
    if cb_ret != 0:
        return Err(
            f"callback failed in _wait_cb_ok: {op_name} (ret={cb_ret}) msg={cb_msg!r}"
        )

    return Ok(cb_ret)


def _immediate_failure(op_name: str, rc: int, state) -> str:
    """Non-zero return: the callback already ran synchronously with the reason."""
    reason = (
        state["msg"].decode("utf-8", errors="replace") if state["done"].is_set() else ""
    )
    return f"{op_name}: immediate call failed (ret={rc})" + (
        f": {reason}" if reason else ""
    )


class NodeWrapper:
    def __init__(self, ctx, config_buffer, event_cb_handler, listener_ids=()):
        self.ctx = ctx
        self._config_buffer = config_buffer
        self._event_cb_handler = event_cb_handler
        self._listener_ids = tuple(listener_ids)

    @staticmethod
    def _make_waiting_cb(state):
        def c_cb(ret, char_p, length, userData):
            ret = int(ret)
            if ret == RET_STALE_WARN:
                return

            msg = ffi.buffer(char_p, length)[:] if char_p != ffi.NULL else b""

            if ret == 0:
                try:
                    decoded = cbor2.loads(msg)
                    if not isinstance(decoded, str):
                        raise TypeError(
                            f"expected string, got {type(decoded).__name__}"
                        )
                    msg = decoded.encode("utf-8")
                except Exception as exc:
                    ret = -1
                    msg = f"invalid CBOR reply: {exc}".encode("utf-8")

            if not state["done"].is_set():
                state["ret"] = ret
                state["msg"] = msg
                state["done"].set()

        return CallbackType(c_cb)

    @staticmethod
    def _make_event_cb(py_callback):
        def c_cb(ret, char_p, length, userData):
            msg = ffi.buffer(char_p, length)[:] if char_p != ffi.NULL else b""
            py_callback(int(ret), msg)

        return CallbackType(c_cb)

    @classmethod
    def create_node(
        cls,
        config: dict,
        event_cb=None,
        *,
        timeout_s: float = 20.0,
    ) -> Result["NodeWrapper", str]:
        config_json = json.dumps(config, separators=(",", ":"), ensure_ascii=False)
        config_buffer, config_len = _encode_request({"configJson": config_json})

        state = _new_cb_state()
        cb = cls._make_waiting_cb(state)

        lib.logosdelivery_create_node(config_buffer, config_len, cb, ffi.NULL)

        wait_result = _wait_cb_ok(state, "create_node", timeout_s)
        if wait_result.is_err():
            return Err(wait_result.err())

        # The constructor reports the context address as decimal text.
        try:
            ctx = ffi.cast("void *", int(state["msg"].decode("utf-8")))
        except Exception as e:
            return Err(f"create_node: invalid context address: {e}")

        if ctx == ffi.NULL:
            return Err("create_node: ctx is NULL")

        event_cb_handler = None
        listener_ids = []
        if event_cb is not None:
            event_cb_handler = cls._make_event_cb(event_cb)
            for event_name in EVENT_NAMES:
                listener_id = lib.logosdelivery_add_event_listener(
                    ctx,
                    event_name.encode("utf-8"),
                    event_cb_handler,
                    ffi.NULL,
                )
                if listener_id == 0:
                    return Err(f"create_node: add_event_listener({event_name}) failed")
                listener_ids.append(listener_id)

        return Ok(cls(ctx, config_buffer, event_cb_handler, listener_ids))

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
        req, req_len = _encode_request({})

        rc = lib.logosdelivery_start_node(self.ctx, cb, ffi.NULL, req, req_len)
        if rc != 0:
            return Err(_immediate_failure("start_node", rc, state))

        return _wait_cb_ok(state, "start_node", timeout_s)

    def stop_node(self, *, timeout_s: float = 20.0) -> Result[int, str]:
        state = _new_cb_state()
        cb = self._make_waiting_cb(state)
        req, req_len = _encode_request({})

        rc = lib.logosdelivery_stop_node(self.ctx, cb, ffi.NULL, req, req_len)
        if rc != 0:
            return Err(_immediate_failure("stop_node", rc, state))

        return _wait_cb_ok(state, "stop_node", timeout_s)

    def destroy(self, *, timeout_s: float = 20.0) -> Result[int, str]:
        if self.ctx == ffi.NULL:
            return Ok(0)

        # Drop the listeners first so the event thread cannot reach the Python
        # callback once the context is gone.
        for listener_id in self._listener_ids:
            lib.logosdelivery_remove_event_listener(self.ctx, listener_id)
        self._listener_ids = ()

        rc = lib.logosdelivery_destroy(self.ctx)
        if rc != 0:
            return Err(f"destroy: call failed (ret={rc})")

        self.ctx = ffi.NULL
        return Ok(rc)

    def stop_and_destroy(self, *, timeout_s: float = 20.0) -> Result[int, str]:
        stop_result = self.stop_node(timeout_s=timeout_s)

        # Destroy even when the stop fails: a node that keeps its context alive
        # also keeps calling back into a wrapper the caller is about to drop.
        destroy_result = self.destroy(timeout_s=timeout_s)

        if stop_result.is_err():
            return Err(stop_result.err())

        return destroy_result

    def subscribe_content_topic(
        self, content_topic: str, *, timeout_s: float = 20.0
    ) -> Result[int, str]:
        state = _new_cb_state()
        cb = self._make_waiting_cb(state)

        req, req_len = _encode_request({"contentTopicStr": content_topic})
        rc = lib.logosdelivery_subscribe(self.ctx, cb, ffi.NULL, req, req_len)
        if rc != 0:
            return Err(_immediate_failure("subscribe_content_topic", rc, state))

        return _wait_cb_ok(state, f"subscribe({content_topic})", timeout_s)

    def unsubscribe_content_topic(
        self, content_topic: str, *, timeout_s: float = 20.0
    ) -> Result[int, str]:
        state = _new_cb_state()
        cb = self._make_waiting_cb(state)

        req, req_len = _encode_request({"contentTopicStr": content_topic})
        rc = lib.logosdelivery_unsubscribe(self.ctx, cb, ffi.NULL, req, req_len)
        if rc != 0:
            return Err(_immediate_failure("unsubscribe_content_topic", rc, state))

        return _wait_cb_ok(state, f"unsubscribe({content_topic})", timeout_s)

    def send_message(
        self, message: dict, *, timeout_s: float = 20.0
    ) -> Result[str, str]:
        state = _new_cb_state()
        cb = self._make_waiting_cb(state)

        message_json = json.dumps(message, separators=(",", ":"), ensure_ascii=False)

        req, req_len = _encode_request({"messageJson": message_json})
        rc = lib.logosdelivery_send(self.ctx, cb, ffi.NULL, req, req_len)
        if rc != 0:
            return Err(_immediate_failure("send_message", rc, state))

        wait_result = _wait_cb_raw(state, "send_message", timeout_s)
        if wait_result.is_err():
            return Err(wait_result.err())

        cb_ret, cb_msg = wait_result.ok_value
        if cb_ret != 0:
            return Err(f"send_message: callback failed (ret={cb_ret}) msg={cb_msg!r}")

        request_id = cb_msg.decode("utf-8") if cb_msg else ""
        return Ok(request_id)

    def get_available_node_info_ids(
        self, *, timeout_s: float = 20.0
    ) -> Result[list[str], str]:
        state = _new_cb_state()
        cb = self._make_waiting_cb(state)
        req, req_len = _encode_request({})

        rc = lib.logosdelivery_get_available_node_info_ids(
            self.ctx, cb, ffi.NULL, req, req_len
        )
        if rc != 0:
            return Err(_immediate_failure("get_available_node_info_ids", rc, state))

        wait_result = _wait_cb_raw(state, "get_available_node_info_ids", timeout_s)
        if wait_result.is_err():
            return Err(wait_result.err())

        cb_ret, cb_msg = wait_result.ok_value
        if cb_ret != 0:
            return Err(f"get_available_node_info_ids: callback failed (ret={cb_ret})")
        if not cb_msg:
            return Err("get_available_node_info_ids: empty response")

        try:
            return Ok(json.loads(cb_msg.decode("utf-8")))
        except Exception as e:
            return Err(f"get_available_node_info_ids: invalid response: {e}")

    def get_node_info(
        self, node_info_id: str, *, timeout_s: float = 20.0
    ) -> Result[str, str]:
        state = _new_cb_state()
        cb = self._make_waiting_cb(state)

        req, req_len = _encode_request({"nodeInfoId": node_info_id})
        rc = lib.logosdelivery_get_node_info(self.ctx, cb, ffi.NULL, req, req_len)
        if rc != 0:
            return Err(_immediate_failure("get_node_info", rc, state))

        wait_result = _wait_cb_raw(state, "get_node_info", timeout_s)
        if wait_result.is_err():
            return Err(wait_result.err())

        cb_ret, cb_msg = wait_result.ok_value
        if cb_ret != 0:
            return Err(f"get_node_info: callback failed (ret={cb_ret}) msg={cb_msg!r}")

        # The item is a plain string, not JSON: a peer id, an ENR URI, a
        # comma-separated multiaddress list or the Prometheus metrics text.
        # MyMixPubKey is legitimately empty when mix is not mounted.
        return Ok(cb_msg.decode("utf-8"))

    def get_available_configs(self, *, timeout_s: float = 20.0) -> Result[dict, str]:
        state = _new_cb_state()
        cb = self._make_waiting_cb(state)
        req, req_len = _encode_request({})

        rc = lib.logosdelivery_get_available_configs(
            self.ctx, cb, ffi.NULL, req, req_len
        )
        if rc != 0:
            return Err(_immediate_failure("get_available_configs", rc, state))

        wait_result = _wait_cb_raw(state, "get_available_configs", timeout_s)
        if wait_result.is_err():
            return Err(wait_result.err())

        cb_ret, cb_msg = wait_result.ok_value
        if cb_ret != 0:
            return Err(
                f"get_available_configs: callback failed (ret={cb_ret}) msg={cb_msg!r}"
            )

        if not cb_msg:
            return Err("get_available_configs: empty response")

        try:
            result = json.loads(cb_msg.decode("utf-8"))
        except Exception as e:
            return Err(f"get_available_configs: invalid json: {e}")

        return Ok(result)

    def destroy_keep_ctx(self, *, timeout_s: float = 20.0) -> Result[int, str]:
        """Destroy the node without nilling self.ctx afterwards.

        Lets a library-contract test reach the C side with a dangling-but-non-nil
        pointer, instead of relying on the binding's defensive nil-out.
        """
        rc = lib.logosdelivery_destroy(self.ctx)
        if rc != 0:
            return Err(f"destroy_keep_ctx: call failed (ret={rc})")

        return Ok(rc)

    def channel_create(
        self,
        channel_id: str,
        content_topic: str,
        sender_id: str,
        *,
        encrypt_fn: int = 0,
        decrypt_fn: int = 0,
        crypto_user_data: int = 0,
        timeout_s: float = 20.0,
    ) -> Result[str, str]:
        state = _new_cb_state()
        cb = self._make_waiting_cb(state)

        req, req_len = _encode_request(
            {
                "channelIdStr": channel_id,
                "contentTopicStr": content_topic,
                "senderIdStr": sender_id,
                "encryptFn": encrypt_fn,
                "decryptFn": decrypt_fn,
                "userData": crypto_user_data,
            },
        )
        rc = lib.logosdelivery_channel_create(self.ctx, cb, ffi.NULL, req, req_len)
        if rc != 0:
            return Err(_immediate_failure("channel_create", rc, state))

        wait_result = _wait_cb_raw(state, f"channel_create({channel_id})", timeout_s)
        if wait_result.is_err():
            return Err(wait_result.err())

        cb_ret, cb_msg = wait_result.ok_value
        if cb_ret != 0:
            return Err(
                cb_msg.decode("utf-8")
                if cb_msg
                else f"channel_create({channel_id}): callback failed (ret={cb_ret})"
            )

        return Ok(cb_msg.decode("utf-8") if cb_msg else "")

    def channel_send(
        self, channel_id: str, message: dict, *, timeout_s: float = 20.0
    ) -> Result[str, str]:
        state = _new_cb_state()
        cb = self._make_waiting_cb(state)

        message_json = json.dumps(message, separators=(",", ":"), ensure_ascii=False)

        req, req_len = _encode_request(
            {"channelIdStr": channel_id, "messageJson": message_json}
        )
        rc = lib.logosdelivery_channel_send(self.ctx, cb, ffi.NULL, req, req_len)
        if rc != 0:
            return Err(_immediate_failure("channel_send", rc, state))

        wait_result = _wait_cb_raw(state, f"channel_send({channel_id})", timeout_s)
        if wait_result.is_err():
            return Err(wait_result.err())

        cb_ret, cb_msg = wait_result.ok_value
        if cb_ret != 0:
            return Err(
                cb_msg.decode("utf-8")
                if cb_msg
                else f"channel_send({channel_id}): callback failed (ret={cb_ret})"
            )

        return Ok(cb_msg.decode("utf-8") if cb_msg else "")

    def channel_close(
        self, channel_id: str, *, timeout_s: float = 20.0
    ) -> Result[str, str]:
        state = _new_cb_state()
        cb = self._make_waiting_cb(state)

        req, req_len = _encode_request({"channelIdStr": channel_id})
        rc = lib.logosdelivery_channel_close(self.ctx, cb, ffi.NULL, req, req_len)
        if rc != 0:
            return Err(_immediate_failure("channel_close", rc, state))

        wait_result = _wait_cb_raw(state, f"channel_close({channel_id})", timeout_s)
        if wait_result.is_err():
            return Err(wait_result.err())

        cb_ret, cb_msg = wait_result.ok_value
        if cb_ret != 0:
            return Err(
                cb_msg.decode("utf-8")
                if cb_msg
                else f"channel_close({channel_id}): callback failed (ret={cb_ret})"
            )

        return Ok(cb_msg.decode("utf-8") if cb_msg else "")
