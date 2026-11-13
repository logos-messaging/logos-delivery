import re
import socket
from src.node.wrappers_manager import WrapperManager
from src.node.wrapper_helpers import (
    EventCollector,
    create_message_bindings,
    get_node_bound_ports,
    get_node_multiaddr,
    get_node_tcp_port,
    is_channel_error_event,
    unique_channel_id,
    wait_for_connected,
    wait_for_event,
    wait_for_mesh,
)

NODE_NOT_STARTED_MSG = "node is not started"
STOPPED_SUBSCRIBE_CONTENT_TOPIC = "/test/1/stopped-subscribe/proto"

SEGMENTS_FAILED_NO_PROVIDER_RE = re.compile(
    r"one or more segments failed: messaging send failed: RequestBroker\(MessagingSend\): no provider registered for broker context \w+"
)
STOPPED_CHANNEL_PREFIX = "stopped-channel"
STOPPED_CHANNEL_CONTENT_TOPIC = "/test/1/stopped-channel/proto"
STOPPED_CHANNEL_SENDER_ID = "stopped-channel-sender"
ERROR_TIMEOUT_S = 10.0


class TestLogosDeliveryLifecycle:
    def _create_start_node(self, node_config, event_cb=None):
        result = WrapperManager.create_and_start(config=node_config, event_cb=event_cb)
        assert result.is_ok(), f"Failed to create and start node: {result.err()}"
        return result.ok_value

    def test_create_start_and_stop_node(self, node_config):
        node = self._create_start_node(node_config)

        stop_result = node.stop_and_destroy()
        assert stop_result.is_ok(), f"Failed to stop and destroy node: {stop_result.err()}"

    def test_stop_node_without_destroy(self, node_config):
        with self._create_start_node(node_config) as node:
            stop_result = node.stop_node()
            assert stop_result.is_ok(), f"Failed to stop node: {stop_result.err()}"

    def test_restart_node(self, node_config):
        with self._create_start_node(node_config) as node:
            stop_result = node.stop_node()
            assert stop_result.is_ok(), f"Failed to stop node: {stop_result.err()}"

            start_result = node.start_node()
            assert start_result.is_ok(), f"Failed to restart node: {start_result.err()}"

    def test_send_on_node_never_started(self, node_config):
        node_config.update({"numShardsInNetwork": 1})
        result = WrapperManager.create(config=node_config)
        assert result.is_ok(), f"Failed to create node: {result.err()}"
        with result.ok_value as node:
            send_result = node.send_message(create_message_bindings())
            assert send_result.is_err(), "send on a node never started succeeded"
            assert f"Send failed: {NODE_NOT_STARTED_MSG}" in send_result.err(), send_result.err()

    def test_subscribe_and_unsubscribe_on_node_never_started(self, node_config):
        node_config.update({"numShardsInNetwork": 1})
        result = WrapperManager.create(config=node_config)
        assert result.is_ok(), f"Failed to create node: {result.err()}"
        with result.ok_value as node:
            subscribe_result = node.subscribe_content_topic(STOPPED_SUBSCRIBE_CONTENT_TOPIC)
            assert subscribe_result.is_err(), "subscribe on a node never started succeeded"
            assert f"Subscribe failed: {NODE_NOT_STARTED_MSG}" in subscribe_result.err(), subscribe_result.err()

            unsubscribe_result = node.unsubscribe_content_topic(STOPPED_SUBSCRIBE_CONTENT_TOPIC)
            assert unsubscribe_result.is_err(), "unsubscribe on a node never started succeeded"
            assert f"Unsubscribe failed: {NODE_NOT_STARTED_MSG}" in unsubscribe_result.err(), unsubscribe_result.err()

    def test_channel_send_on_node_never_started(self, node_config):
        # TODO: logos-delivery#4543
        node_config.update({"numShardsInNetwork": 1})
        node_collector = EventCollector()
        result = WrapperManager.create(config=node_config, event_cb=node_collector.event_callback)
        assert result.is_ok(), f"Failed to create node: {result.err()}"
        with result.ok_value as node:
            channel_id = unique_channel_id(STOPPED_CHANNEL_PREFIX)
            create_result = node.channel_create(channel_id, STOPPED_CHANNEL_CONTENT_TOPIC, STOPPED_CHANNEL_SENDER_ID)
            assert create_result.is_ok(), f"channel_create failed: {create_result.err()}"

            send_result = node.channel_send(channel_id, create_message_bindings())
            assert send_result.is_ok(), f"channel_send on a node never started failed: {send_result.err()}"
            request_id = send_result.ok_value

            # The channel event gives the error of the failed send. A message
            # event carries a message hash, and this send got none.
            channel_error_event = wait_for_event(node_collector, request_id, is_channel_error_event, ERROR_TIMEOUT_S)
            assert channel_error_event is not None, f"no channel_message_error for request {request_id}. Collected events: {node_collector.events}"
            assert channel_error_event["channelId"] == channel_id, channel_error_event
            assert SEGMENTS_FAILED_NO_PROVIDER_RE.fullmatch(channel_error_event["error"]), channel_error_event

    def test_channel_send_after_restart_on_channel_created_before_stop(self, node_config):
        # TODO: logos-delivery#4554
        # stop_node drops the channel, so creating it again under the same id succeeds.
        node_config.update({"numShardsInNetwork": 1})
        with self._create_start_node(node_config) as node:
            channel_id = unique_channel_id(STOPPED_CHANNEL_PREFIX)
            create_result = node.channel_create(channel_id, STOPPED_CHANNEL_CONTENT_TOPIC, STOPPED_CHANNEL_SENDER_ID)
            assert create_result.is_ok(), f"channel_create failed: {create_result.err()}"

            stop_result = node.stop_node()
            assert stop_result.is_ok(), f"Failed to stop node: {stop_result.err()}"

            stopped_send_result = node.channel_send(channel_id, create_message_bindings())
            assert stopped_send_result.is_err(), "channel_send after stop_node on a channel created before the stop succeeded"
            assert f"ChannelSend failed: unknown channel: {channel_id}" in stopped_send_result.err(), stopped_send_result.err()

            start_result = node.start_node()
            assert start_result.is_ok(), f"Failed to restart node: {start_result.err()}"

            send_result = node.channel_send(channel_id, create_message_bindings())
            assert send_result.is_err(), "channel_send after restart on a channel created before stop_node succeeded"
            assert f"ChannelSend failed: unknown channel: {channel_id}" in send_result.err(), send_result.err()

            close_result = node.channel_close(channel_id)
            assert close_result.is_err(), "channel_close after restart on a channel created before stop_node succeeded"
            assert f"ChannelClose failed: unknown channel: {channel_id}" in close_result.err(), close_result.err()

            recreate_result = node.channel_create(channel_id, STOPPED_CHANNEL_CONTENT_TOPIC, STOPPED_CHANNEL_SENDER_ID)
            assert recreate_result.is_ok(), f"channel_create after restart failed: {recreate_result.err()}"
            assert recreate_result.ok_value == channel_id, recreate_result.ok_value

    def test_restart_node_with_rest(self, node_config):
        node_config.update({"numShardsInNetwork": 1})
        with self._create_start_node({**node_config, "rest": True}) as node:
            rest_port = get_node_bound_ports(node)["rest"]
            stop_result = node.stop_node()
            assert stop_result.is_ok(), f"Failed to stop node: {stop_result.err()}"
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
                assert s.connect_ex(("127.0.0.1", rest_port)) != 0, "REST port accepted a connection after stop_node"

            start_result = node.start_node()
            assert start_result.is_ok(), f"Failed to restart node: {start_result.err()}"
            assert get_node_bound_ports(node)["rest"] == rest_port, "REST bound another port after the restart"

            peer_collector = EventCollector()
            with self._create_start_node({**node_config, "staticnodes": [get_node_multiaddr(node)]}, peer_collector.event_callback):
                assert wait_for_mesh(peer_collector), "peer never meshed with the restarted node"

    def test_second_start_node_is_a_noop(self, node_config):
        # A start_node on a running node returns ok and leaves REST on its port.
        node_config.update({"numShardsInNetwork": 1})
        with self._create_start_node({**node_config, "rest": True}) as node:
            rest_port = get_node_bound_ports(node)["rest"]
            assert rest_port != 0, "REST did not bind a port"

            start_result = node.start_node()
            assert start_result.is_ok(), f"Second start_node failed: {start_result.err()}"
            assert get_node_bound_ports(node)["rest"] == rest_port, "REST bound another port after the second start_node"
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
                assert s.connect_ex(("127.0.0.1", rest_port)) == 0, "REST port refused a connection after the second start_node"

            stop_result = node.stop_node()
            assert stop_result.is_ok(), f"Failed to stop node: {stop_result.err()}"
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
                assert s.connect_ex(("127.0.0.1", rest_port)) != 0, "REST port accepted a connection after stop_node"

    def test_restart_node_with_metrics_server(self, node_config):
        node_config.update({"numShardsInNetwork": 1})
        with self._create_start_node({**node_config, "metricsServer": True, "metricsServerPort": 0}) as node:
            stop_result = node.stop_node()
            assert stop_result.is_ok(), f"Failed to stop node: {stop_result.err()}"

            start_result = node.start_node()
            assert start_result.is_ok(), f"Failed to restart node: {start_result.err()}"

            peer_collector = EventCollector()
            with self._create_start_node({**node_config, "staticnodes": [get_node_multiaddr(node)]}, peer_collector.event_callback):
                assert wait_for_mesh(peer_collector), "peer never meshed with the restarted node"

            stop_result = node.stop_node()
            assert stop_result.is_ok(), f"Failed to stop node: {stop_result.err()}"

    def test_peer_meshes_with_started_node(self, node_config):
        node_config.update({"numShardsInNetwork": 1})
        with self._create_start_node(node_config) as node:
            peer_collector = EventCollector()
            with self._create_start_node({**node_config, "staticnodes": [get_node_multiaddr(node)]}, peer_collector.event_callback):
                assert wait_for_mesh(peer_collector), "peer never meshed with the node"

    def test_peer_meshes_with_node_at_dns4_localhost(self, node_config):
        # The name goes through the host's resolver when no DNS server is configured.
        node_config.update({"numShardsInNetwork": 1})
        with self._create_start_node(node_config) as node:
            peer_id_result = node.get_node_info("MyPeerId")
            assert peer_id_result.is_ok(), f"MyPeerId query failed: {peer_id_result.err()}"
            dns4_multiaddr = f"/dns4/localhost/tcp/{get_node_tcp_port(node)}/p2p/{peer_id_result.ok_value.strip()}"
            peer_collector = EventCollector()
            with self._create_start_node({**node_config, "staticnodes": [dns4_multiaddr]}, peer_collector.event_callback):
                assert wait_for_mesh(peer_collector), "peer never meshed with the node at a /dns4/localhost address"

    def test_peer_meshes_with_restarted_node(self, node_config):
        # A restarted node accepts the peers that connect after the restart.
        # nim-libp2p before 2.4.0 kept the connection manager closed after a stop,
        # so a restarted node dropped every inbound stream (nim-libp2p PR 3068).
        node_config.update({"numShardsInNetwork": 1})
        with self._create_start_node(node_config) as node:
            stop_result = node.stop_node()
            assert stop_result.is_ok(), f"Failed to stop node: {stop_result.err()}"

            start_result = node.start_node()
            assert start_result.is_ok(), f"Failed to restart node: {start_result.err()}"

            peer_collector = EventCollector()
            with self._create_start_node({**node_config, "staticnodes": [get_node_multiaddr(node)]}, peer_collector.event_callback):
                assert wait_for_mesh(peer_collector), "peer never meshed with the restarted node"

    def test_listener_receives_events_after_restart(self, node_config):
        # The binding registers event_cb only when it creates the node.
        node_config.update({"numShardsInNetwork": 1})
        node_collector = EventCollector()
        with self._create_start_node(node_config, node_collector.event_callback) as node:
            stop_result = node.stop_node()
            assert stop_result.is_ok(), f"Failed to stop node: {stop_result.err()}"

            start_result = node.start_node()
            assert start_result.is_ok(), f"Failed to restart node: {start_result.err()}"

            with self._create_start_node({**node_config, "staticnodes": [get_node_multiaddr(node)]}):
                assert wait_for_connected(node_collector), "listener added at create got no event after stop_node and start_node"

    def test_recreate_node_after_destroy(self, node_config):
        node = self._create_start_node(node_config)
        stop_result = node.stop_and_destroy()
        assert stop_result.is_ok(), f"Failed to stop and destroy node: {stop_result.err()}"

        node = self._create_start_node(node_config)
        stop_result = node.stop_and_destroy()
        assert stop_result.is_ok(), f"Failed to stop and destroy node: {stop_result.err()}"
