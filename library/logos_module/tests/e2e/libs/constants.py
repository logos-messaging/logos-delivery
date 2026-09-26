"""Networking + waku-cluster constants for the two-daemon e2e fixtures."""

from __future__ import annotations

NETWORK_SUBNET = "172.31.0.0/16"

CLUSTER_ID = "198"
NUM_SHARDS_IN_NETWORK = 1

NODE_TCP_PORT = 60000

CONTENT_TOPIC = "/test/1/logos-delivery-e2e/proto"
