"""S01 helpers: invoke send() against an invalid handle in an isolated process.

Run via:
    python -m tests.wrappers_tests.helpers.send_on_invalid_handle nil       <marker>
    python -m tests.wrappers_tests.helpers.send_on_invalid_handle destroyed <marker>

Prints a single line to stdout starting with <marker>, followed by a JSON
payload describing the outcome. Runs in its own process so that a missing
C-ABI guard (which can SIGSEGV) fails the parent test cleanly instead of
taking the pytest runner down.

Cases:
- nil:       send() on a wrapper built with ctx=ffi.NULL.
- destroyed: send() after destroy_keep_ctx() — self.ctx stays non-nil so the
             call reaches the C side with the original (now-stale) pointer.
"""

import json
import sys
from pathlib import Path


def _ensure_bindings_on_path() -> None:
    # The wrapper module lives outside the project tree, under vendor/.
    # Helper file is at <root>/tests/wrappers_tests/helpers/<this>.py.
    project_root = Path(__file__).resolve().parents[3]
    bindings_path = project_root / "vendor" / "logos-delivery-python-bindings" / "waku"
    if str(bindings_path) not in sys.path:
        sys.path.insert(0, str(bindings_path))
    if str(project_root) not in sys.path:
        sys.path.insert(0, str(project_root))


def _emit(marker: str, payload: dict) -> None:
    print(marker + json.dumps(payload))


def _run_nil_handle(marker: str) -> None:
    from wrapper import NodeWrapper, ffi  # type: ignore[import-not-found]
    from src.node.wrappers_manager import WrapperManager
    from src.node.wrapper_helpers import create_message_bindings

    sender = WrapperManager(NodeWrapper(ctx=ffi.NULL, config_buffer=None, event_cb_handler=None))
    send_result = sender.send_message(message=create_message_bindings())

    _emit(
        marker,
        {
            "is_ok": send_result.is_ok(),
            "ok": send_result.ok_value if send_result.is_ok() else None,
            "err": send_result.err() if send_result.is_err() else None,
        },
    )


def _run_destroyed_handle(marker: str) -> None:
    from src.node.wrappers_manager import WrapperManager
    from src.node.wrapper_helpers import EventCollector, create_message_bindings
    from tests.wrappers_tests.conftest import build_node_config

    collector = EventCollector()

    create_result = WrapperManager.create_and_start(
        config=build_node_config(),
        event_cb=collector.event_callback,
    )
    if create_result.is_err():
        _emit(
            marker,
            {
                "stage": "create_and_start",
                "is_ok": False,
                "ok": None,
                "err": create_result.err(),
                "events_after_send": [],
            },
        )
        return

    sender = create_result.ok_value

    stop_result = sender.stop_node()
    if stop_result.is_err():
        _emit(
            marker,
            {
                "stage": "stop_node",
                "is_ok": False,
                "ok": None,
                "err": stop_result.err(),
                "events_after_send": [],
            },
        )
        return

    destroy_result = sender.destroy_keep_ctx()
    if destroy_result.is_err():
        _emit(
            marker,
            {
                "stage": "destroy_keep_ctx",
                "is_ok": False,
                "ok": None,
                "err": destroy_result.err(),
                "events_after_send": [],
            },
        )
        return

    events_before_send = len(collector.events)

    send_result = sender.send_message(message=create_message_bindings())

    new_events = collector.events[events_before_send:]

    _emit(
        marker,
        {
            "stage": "send_message",
            "is_ok": send_result.is_ok(),
            "ok": send_result.ok_value if send_result.is_ok() else None,
            "err": send_result.err() if send_result.is_err() else None,
            "events_after_send": [str(e) for e in new_events],
        },
    )


CASES = {
    "nil": _run_nil_handle,
    "destroyed": _run_destroyed_handle,
}


def main() -> int:
    if len(sys.argv) != 3 or sys.argv[1] not in CASES:
        cases = "|".join(CASES)
        print(f"usage: send_on_invalid_handle <{cases}> <result_marker>", file=sys.stderr)
        return 2

    case, marker = sys.argv[1], sys.argv[2]

    _ensure_bindings_on_path()
    CASES[case](marker)
    return 0


if __name__ == "__main__":
    sys.exit(main())
