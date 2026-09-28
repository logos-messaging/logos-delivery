from src.node.wrappers_manager import WrapperManager
from src.node.wrapper_helpers import EventCollector, get_node_multiaddr, wait_for_mesh


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
        node = self._create_start_node(node_config)

        try:
            stop_result = node.stop_node()
            assert stop_result.is_ok(), f"Failed to stop node: {stop_result.err()}"
        finally:
            destroy_result = node.destroy()
            assert destroy_result.is_ok(), f"Failed to destroy node: {destroy_result.err()}"

    def test_restart_node(self, node_config):
        node = self._create_start_node(node_config)

        try:
            stop_result = node.stop_node()
            assert stop_result.is_ok(), f"Failed to stop node: {stop_result.err()}"

            start_result = node.start_node()
            assert start_result.is_ok(), f"Failed to restart node: {start_result.err()}"
        finally:
            stop_result = node.stop_and_destroy()
            assert stop_result.is_ok(), f"Failed to stop and destroy node: {stop_result.err()}"

    def test_peer_meshes_with_started_node(self, node_config):
        node_config.update({"numShardsInNetwork": 1})
        node = self._create_start_node(node_config)

        try:
            peer_collector = EventCollector()
            peer = self._create_start_node({**node_config, "staticnodes": [get_node_multiaddr(node)]}, peer_collector.event_callback)
            try:
                assert wait_for_mesh(peer_collector), "peer never meshed with the node"
            finally:
                stop_result = peer.stop_and_destroy()
                assert stop_result.is_ok(), f"Failed to stop and destroy peer: {stop_result.err()}"
        finally:
            stop_result = node.stop_and_destroy()
            assert stop_result.is_ok(), f"Failed to stop and destroy node: {stop_result.err()}"

    def test_peer_cannot_mesh_with_restarted_node(self, node_config):
        # Current behaviour, questioned: a restarted node rejects every peer that connects after the restart.
        node_config.update({"numShardsInNetwork": 1})
        node = self._create_start_node(node_config)

        try:
            stop_result = node.stop_node()
            assert stop_result.is_ok(), f"Failed to stop node: {stop_result.err()}"

            start_result = node.start_node()
            assert start_result.is_ok(), f"Failed to restart node: {start_result.err()}"

            peer_collector = EventCollector()
            peer = self._create_start_node({**node_config, "staticnodes": [get_node_multiaddr(node)]}, peer_collector.event_callback)
            try:
                assert not wait_for_mesh(peer_collector), "peer meshed with the restarted node"
            finally:
                stop_result = peer.stop_and_destroy()
                assert stop_result.is_ok(), f"Failed to stop and destroy peer: {stop_result.err()}"
        finally:
            stop_result = node.stop_and_destroy()
            assert stop_result.is_ok(), f"Failed to stop and destroy node: {stop_result.err()}"

    def test_recreate_node_after_destroy(self, node_config):
        node = self._create_start_node(node_config)
        stop_result = node.stop_and_destroy()
        assert stop_result.is_ok(), f"Failed to stop and destroy node: {stop_result.err()}"

        node = self._create_start_node(node_config)
        stop_result = node.stop_and_destroy()
        assert stop_result.is_ok(), f"Failed to stop and destroy node: {stop_result.err()}"
