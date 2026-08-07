import pytest
from src.steps.common import StepsCommon
from src.libs.custom_logger import get_custom_logger
from src.node.wrappers_manager import WrapperManager
from src.node.wrapper_helpers import (
    EventCollector,
    create_message_bindings,
    enr_udp_port,
    get_node_bound_ports,
    get_node_multiaddr,
    get_node_tcp_port,
    wait_for_propagated,
)
from tests.wrappers_tests.conftest import build_node_config, free_port

logger = get_custom_logger(__name__)

PROPAGATED_TIMEOUT_S = 30.0

# The five service ports covered by logos-messaging/logos-delivery#3828:
# (config field, key in MyBoundPorts, config to enable the service, default port)
SERVICE_PORTS = [
    ("tcpPort", "tcp", {}, 60000),
    ("discv5UdpPort", "discv5Udp", {"discv5Discovery": True}, 9000),
    ("websocketPort", "webSocket", {"websocketSupport": True}, 8000),
    ("restPort", "rest", {"rest": True}, 8645),
    ("metricsServerPort", "metrics", {"metricsServer": True}, 8008),
]


class TestWrapperAutoPortAllocation(StepsCommon):
    """Corner case: port 0 triggers auto-port allocation.

    Tracks logos-messaging/logos-delivery#3828:
    - any service port set to 0 gets a free port auto-assigned at bind time
    - defaults remain concrete, so auto-port is opt-in via an explicit 0
    - bound values are exposed through MyBoundPorts (0 = service disabled)
    - the ENR is rebuilt after discv5 startup, so it advertises the
      actually-bound UDP port instead of the configured 0
    """

    def test_auto_port_starts_node_with_tcp_and_discv5_zero(self):
        config = build_node_config(tcpPort=0, discv5UdpPort=0)
        result = WrapperManager.create_and_start(config=config)
        assert result.is_ok(), f"create_and_start failed: {result.err()}"

        with result.ok_value as node:
            tcp_port = get_node_tcp_port(node)
            assert tcp_port != 0, "multiaddr still reports port 0; auto-port did not happen"
            assert get_node_bound_ports(node)["tcp"] == tcp_port, "MyBoundPorts disagrees with the multiaddr port"

    def test_auto_port_node_can_propagate_message(self):
        # End-to-end: two auto-port nodes exchange a message.
        # numShardsInNetwork=1 enables autosharding, required by the send API.
        collector = EventCollector()
        sender_config = build_node_config(tcpPort=0, discv5UdpPort=0, numShardsInNetwork=1)
        sender_result = WrapperManager.create_and_start(config=sender_config, event_cb=collector.event_callback)
        assert sender_result.is_ok(), f"sender start failed: {sender_result.err()}"

        with sender_result.ok_value as sender:
            peer_config = build_node_config(
                tcpPort=0,
                discv5UdpPort=0,
                numShardsInNetwork=1,
                staticnodes=[get_node_multiaddr(sender)],
            )
            peer_result = WrapperManager.create_and_start(config=peer_config)
            assert peer_result.is_ok(), f"peer start failed: {peer_result.err()}"

            with peer_result.ok_value:
                send_result = sender.send_message(message=create_message_bindings())
                assert send_result.is_ok(), f"send failed: {send_result.err()}"

                request_id = send_result.ok_value
                assert request_id, "send returned empty RequestId"

                propagated = wait_for_propagated(collector, request_id, PROPAGATED_TIMEOUT_S)
                assert propagated is not None, f"no message_propagated event. Events: {collector.events}"

    @pytest.mark.parametrize("port_field, bound_key, enable_service, default_port", SERVICE_PORTS)
    def test_auto_port_per_field(self, port_field, bound_key, enable_service, default_port):
        # Each service port set to 0 in isolation, with its service enabled.
        config = build_node_config(**{port_field: 0}, **enable_service)
        result = WrapperManager.create_and_start(config=config)
        assert result.is_ok(), f"create_and_start failed with {port_field}=0: {result.err()}"

        with result.ok_value as node:
            port = get_node_bound_ports(node)[bound_key]
            assert port != 0, f"{port_field}=0 but nothing bound; auto-port did not happen"
            assert port != default_port, f"{port_field}=0 bound the default {default_port}; expected an ephemeral port"

    def test_concrete_ports_are_respected(self):
        # Auto-port is opt-in: non-zero ports must bind exactly as requested.
        requested = {field: free_port() for field, _, _, _ in SERVICE_PORTS}
        enable_all = {key: value for _, _, enable, _ in SERVICE_PORTS for key, value in enable.items()}

        config = build_node_config(**requested, **enable_all)
        result = WrapperManager.create_and_start(config=config)
        assert result.is_ok(), f"create_and_start failed: {result.err()}"

        with result.ok_value as node:
            bound = get_node_bound_ports(node)
            for field, bound_key, _, _ in SERVICE_PORTS:
                assert bound[bound_key] == requested[field], f"{field}: requested {requested[field]}, bound {bound[bound_key]}"

    def test_bound_ports_zero_for_disabled_services(self):
        # build_node_config leaves websocket, REST, metrics and discv5 off.
        result = WrapperManager.create_and_start(config=build_node_config())
        assert result.is_ok(), f"create_and_start failed: {result.err()}"

        with result.ok_value as node:
            bound = get_node_bound_ports(node)
            assert bound["tcp"] != 0, "tcp is enabled but reports port 0"
            for key in ("webSocket", "rest", "discv5Udp", "metrics"):
                assert bound[key] == 0, f"{key} is disabled but reports port {bound[key]}"

    def test_enr_advertises_bound_discv5_port(self):
        # #3828 rebuilds the ENR after discv5 startup so it advertises the
        # actually-bound UDP port, not the configured 0.
        config = build_node_config(discv5UdpPort=0, discv5Discovery=True)
        result = WrapperManager.create_and_start(config=config)
        assert result.is_ok(), f"create_and_start failed: {result.err()}"

        with result.ok_value as node:
            discv5_port = get_node_bound_ports(node)["discv5Udp"]
            assert discv5_port != 0, "discv5 enabled with port 0 but nothing bound"

            enr_result = node.get_node_info("MyENR")
            assert enr_result.is_ok(), f"MyENR query failed: {enr_result.err()}"
            assert enr_udp_port(enr_result.ok_value.strip()) == discv5_port, "ENR was not rebuilt after discv5 startup"
