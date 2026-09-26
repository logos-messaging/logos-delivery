"""Single-daemon e2e checks.

These prove delivery_module loads into a real logoscore daemon and answers over
RPC — the codegen + transport + StdLogosResult path the in-process C++ tests
don't exercise. Each uses a fresh daemon (createNode is once-per-context).
"""

from __future__ import annotations

from libs.constants import CONTENT_TOPIC
from libs.helpers import LogosDelivery, make_delivery_config


def test_create_start_and_stop_node(solo_daemon):
    delivery = LogosDelivery(solo_daemon.client())
    delivery.load()
    delivery.create_node(make_delivery_config())
    delivery.start()
    delivery.stop()


def test_createNode_twice_rejected(solo_daemon):
    delivery = LogosDelivery(solo_daemon.client())
    delivery.load()
    delivery.create_node(make_delivery_config())

    second = delivery.create_node_result(make_delivery_config())
    assert second.get("success") is False, f"expected the second createNode to be rejected, got {second!r}"
    assert second.get("error"), "rejection carried no error message"


def test_query_and_subscribe_methods(solo_daemon):
    """Every post-start RPC method round-trips: the queries, plus subscribe +
    unsubscribe (the only public methods otherwise unexercised e2e)."""
    delivery = LogosDelivery(solo_daemon.client())
    delivery.load()
    delivery.create_node(make_delivery_config())
    delivery.start()

    assert delivery.get_available_configs(), "getAvailableConfigs returned empty"
    assert delivery.get_available_node_info_ids(), "getAvailableNodeInfoIDs returned empty"

    for info_id in ("Version", "MyPeerId", "MyMultiaddresses"):
        delivery.get_node_info(info_id)

    delivery.subscribe(CONTENT_TOPIC)
    delivery.unsubscribe(CONTENT_TOPIC)
