import socket
import pytest
from src.test_data import DEFAULT_CLUSTER_ID


def free_port():
    """Return a currently-unbound TCP/UDP port from the OS."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("", 0))
        return s.getsockname()[1]


def build_node_config(**overrides):
    config = {
        "logLevel": "DEBUG",
        "listenAddress": "0.0.0.0",
        "tcpPort": free_port(),
        "discv5UdpPort": free_port(),
        "restPort": free_port(),
        "restAddress": "0.0.0.0",
        "clusterId": DEFAULT_CLUSTER_ID,
        "relay": True,
        "store": True,
        "filter": False,
        "lightpush": False,
        "peerExchange": False,
        "discv5Discovery": False,
        "nat": "none",
    }
    config.update(overrides)
    return config


@pytest.fixture
def node_config():
    return build_node_config()
