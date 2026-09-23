CONTENT_TOPICS_DIFFERENT_SHARDS = [
    "/myapp/1/latest/proto",  # resolves to shard 0
    "/waku/2/content/test.js",  # resolves to shard 1
    "/app/22/sometopic/someencoding",  # resolves to shard 2
    "/toychat/2/huilong/proto",  # resolves to shard 3
    "/statusim/1/community/cbor",  # resolves to shard 4
    "/app/27/sometopic/someencoding",  # resolves to shard 5
    "/app/29/sometopic/someencoding",  # resolves to shard 6
    "/app/20/sometopic/someencoding",  # resolves to shard 7
]

DEFAULT_CLUSTER_ID = "198"
DEFAULT_SHARD = "0"

FLEET_PRESET = "logos.test"
# Autosharding maps the fleet tests' content topics, /fleet-test/1/..., to shard 6.
FLEET_SHARDS = ["6"]

VALID_PUBSUB_TOPICS = [
    f"/waku/2/rs/{DEFAULT_CLUSTER_ID}/0",
    f"/waku/2/rs/{DEFAULT_CLUSTER_ID}/1",
    f"/waku/2/rs/{DEFAULT_CLUSTER_ID}/9",
    f"/waku/2/rs/{DEFAULT_CLUSTER_ID}/25",
    f"/waku/2/rs/{DEFAULT_CLUSTER_ID}/1000",
]

PUBSUB_TOPICS_RLN = [f"/waku/2/rs/{DEFAULT_CLUSTER_ID}/0"]

LOG_ERROR_KEYWORDS = [
    "crash",
    "fatal",
    "panic",
    "abort",
    "segfault",
    "corrupt",
    "terminated",
    "unhandled",
    "stacktrace",
    "deadlock",
    "SIGSEGV",
    "SIGABRT",
    "stack overflow",
    "index out of bounds",
    "nil pointer dereference",
    "goroutine exit",
    "nil pointer",
    "runtime error",
    "goexit",
    "race condition",
    "double free",
]
