"""logos.dev fleet definition and helpers shared by the validation scripts."""

import hashlib

FLEET = {
    "ams": [
        ("delivery-01.do-ams3.logos.dev.status.im", "16Uiu2HAmTUbnxLGT9JvV6mu9oPyDjqHK4Phs1VDJNUgESgNSkuby"),
        ("delivery-02.do-ams3.logos.dev.status.im", "16Uiu2HAmMK7PYygBtKUQ8EHp7EfaD3bCEsJrkFooK8RQ2PVpJprH"),
    ],
    "us": [
        ("delivery-01.gc-us-central1-a.logos.dev.status.im", "16Uiu2HAm4S1JYkuzDKLKQvwgAhZKs9otxXqt8SCGtB4hoJP1S397"),
        ("delivery-02.gc-us-central1-a.logos.dev.status.im", "16Uiu2HAm8Y9kgBNtjxvCnf1X6gnZJW5EGE4UwwCL3CCm55TwqBiH"),
    ],
    "hk": [
        ("delivery-01.ac-cn-hongkong-c.logos.dev.status.im", "16Uiu2HAm8YokiNun9BkeA1ZRmhLbtNUvcwRr64F69tYj9fkGyuEP"),
        ("delivery-02.ac-cn-hongkong-c.logos.dev.status.im", "16Uiu2HAkvwhGHKNry6LACrB8TmEFoCJKEX29XR5dDUzk3UT3UNSE"),
    ],
}

# Local ports that fleet_tunnels.sh forwards to each node's metrics endpoint.
METRICS_PORTS = {
    host: 18001 + i
    for i, (host, _) in enumerate(n for dc in ("ams", "us", "hk") for n in FLEET[dc])
}

P2P_PORT = 30303
NUM_SHARDS = 8


def multiaddr(host: str, peer_id: str, transport: str) -> str:
    if transport == "quic":
        return f"/dns4/{host}/udp/{P2P_PORT}/quic-v1/p2p/{peer_id}"
    return f"/dns4/{host}/tcp/{P2P_PORT}/p2p/{peer_id}"


def entry_nodes(dc: str, transport: str) -> list:
    return [multiaddr(h, p, transport) for h, p in FLEET[dc]]


def shard_of(content_topic: str, num_shards: int = NUM_SHARDS) -> int:
    """Mirror of getGenZeroShard: sha256(application & version), last 8 bytes BE."""
    _, app, version, _, _ = content_topic.split("/")
    digest = hashlib.sha256((app + version).encode()).digest()
    return int.from_bytes(digest[24:32], "big") % num_shards


def topic_for_shard(run_id: str, shard: int) -> str:
    """First content topic under this run's namespace that lands on `shard`."""
    for n in range(10_000):
        topic = f"/fv-{run_id}-{n}/1/load/json"
        if shard_of(topic) == shard:
            return topic
    raise RuntimeError(f"no topic found for shard {shard}")
