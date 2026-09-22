from src.libs.common import wait_until
from src.node.waku_node import peer_info2id
from src.steps.relay import StepsRelay


class TestPeerStore(StepsRelay):
    def test_use_persistent_storage_survive_restart(self):
        self.setup_first_relay_node(peer_persistence="true")
        self.setup_second_relay_node()
        node2_id = self.node2.get_id()

        def node2_connected():
            return any(peer_info2id(peer) == node2_id and peer["connected"] == "Connected" for peer in self.node1.get_peers())

        wait_until(node2_connected, message=f"Expected {node2_id} connected to node1")
        # With node2 stopped, node1 can learn of it after the restart only from its peer storage.
        self.node2.stop()
        self.node1.restart()

        def node2_listed():
            return node2_id in {peer_info2id(peer) for peer in self.node1.get_peers()}

        wait_until(node2_listed, message=f"Expected {node2_id} among node1's peers after its restart")
