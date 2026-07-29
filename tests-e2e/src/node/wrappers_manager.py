import sys
from pathlib import Path
from result import Result, Ok, Err

_BINDINGS_PATH = Path(__file__).resolve().parents[2] / "vendor" / "logos-delivery-python-bindings" / "waku"
if str(_BINDINGS_PATH) not in sys.path:
    sys.path.insert(0, str(_BINDINGS_PATH))

from wrapper import NodeWrapper as _NodeWrapper  # type: ignore[import]

""""
thin manager/wrapper layer around NodeWrapper from the bindings.
It simplifies  create, start, and interaction with a Waku node while returning consistent Result objects (Ok / Err).
"""


class WrapperManager:
    def __init__(self, node: _NodeWrapper):
        self._node = node

    @classmethod
    def create(
        cls,
        config: dict,
        event_cb=None,
        *,
        timeout_s: float = 20.0,
    ) -> Result["WrapperManager", str]:
        result = _NodeWrapper.create_node(config, event_cb, timeout_s=timeout_s)
        if result.is_err():
            return Err(result.err())
        return Ok(cls(result.ok_value))

    @classmethod
    def create_and_start(
        cls,
        config: dict,
        event_cb=None,
        *,
        timeout_s: float = 20.0,
    ) -> Result["WrapperManager", str]:
        result = _NodeWrapper.create_and_start(config, event_cb, timeout_s=timeout_s)
        if result.is_err():
            return Err(result.err())
        return Ok(cls(result.ok_value))

    def __enter__(self) -> "WrapperManager":
        return self

    def __exit__(self, *_) -> None:
        self.stop_and_destroy()

    def start_node(self, *, timeout_s: float = 20.0) -> Result[int, str]:
        return self._node.start_node(timeout_s=timeout_s)

    def stop_node(self, *, timeout_s: float = 20.0) -> Result[int, str]:
        return self._node.stop_node(timeout_s=timeout_s)

    def destroy(self, *, timeout_s: float = 20.0) -> Result[int, str]:
        return self._node.destroy(timeout_s=timeout_s)

    def stop_and_destroy(self, *, timeout_s: float = 20.0) -> Result[int, str]:
        return self._node.stop_and_destroy(timeout_s=timeout_s)

    def destroy_keep_ctx(self, *, timeout_s: float = 20.0) -> Result[int, str]:
        """Pass-through for NodeWrapper.destroy_keep_ctx — see that method."""
        return self._node.destroy_keep_ctx(timeout_s=timeout_s)

    def subscribe_content_topic(self, content_topic: str, *, timeout_s: float = 20.0) -> Result[int, str]:
        return self._node.subscribe_content_topic(content_topic, timeout_s=timeout_s)

    def unsubscribe_content_topic(self, content_topic: str, *, timeout_s: float = 20.0) -> Result[int, str]:
        return self._node.unsubscribe_content_topic(content_topic, timeout_s=timeout_s)

    def send_message(self, message: dict, *, timeout_s: float = 20.0) -> Result[str, str]:
        return self._node.send_message(message, timeout_s=timeout_s)

    def channel_create(
        self,
        channel_id: str,
        content_topic: str,
        sender_id: str,
        *,
        timeout_s: float = 20.0,
    ) -> Result[str, str]:
        return self._node.channel_create(channel_id, content_topic, sender_id, timeout_s=timeout_s)

    def channel_send(self, channel_id: str, message: dict, *, timeout_s: float = 20.0) -> Result[str, str]:
        return self._node.channel_send(channel_id, message, timeout_s=timeout_s)

    def channel_close(self, channel_id: str, *, timeout_s: float = 20.0) -> Result[int, str]:
        return self._node.channel_close(channel_id, timeout_s=timeout_s)

    def get_available_node_info_ids(self, *, timeout_s: float = 20.0) -> Result[list[str], str]:
        return self._node.get_available_node_info_ids(timeout_s=timeout_s)

    def get_node_info(self, node_info_id: str, *, timeout_s: float = 20.0) -> Result[dict, str]:
        return self._node.get_node_info(node_info_id, timeout_s=timeout_s)

    def get_node_info_raw(self, node_info_id: str, *, timeout_s: float = 20.0) -> Result[str, str]:
        """Like get_node_info but returns the raw string without JSON parsing."""
        from wrapper import lib, ffi, _new_cb_state, _wait_cb_raw  # type: ignore[import]

        state = _new_cb_state()
        cb = self._node._make_waiting_cb(state)
        rc = lib.logosdelivery_get_node_info(self._node.ctx, cb, ffi.NULL, node_info_id.encode("utf-8"))
        if rc != 0:
            return Err(f"get_node_info_raw: immediate call failed (ret={rc})")
        wait_result = _wait_cb_raw(state, "get_node_info_raw", timeout_s)
        if wait_result.is_err():
            return Err(wait_result.err())
        cb_ret, cb_msg = wait_result.ok_value
        if cb_ret != 0:
            return Err(f"get_node_info_raw: callback failed (ret={cb_ret})")
        return Ok(cb_msg.decode("utf-8") if cb_msg else "")

    def get_available_configs(self, *, timeout_s: float = 20.0) -> Result[dict, str]:
        return self._node.get_available_configs(timeout_s=timeout_s)
