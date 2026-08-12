import pytest
from src.node.wrappers_manager import WrapperManager


@pytest.mark.smoke
class TestLogosDeliveryLifecycle:
    def _create_start_node(self, node_config):
        result = WrapperManager.create_and_start(config=node_config)
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

    def test_recreate_node_after_destroy(self, node_config):
        node = self._create_start_node(node_config)
        stop_result = node.stop_and_destroy()
        assert stop_result.is_ok(), f"Failed to stop and destroy node: {stop_result.err()}"

        node = self._create_start_node(node_config)
        stop_result = node.stop_and_destroy()
        assert stop_result.is_ok(), f"Failed to stop and destroy node: {stop_result.err()}"
