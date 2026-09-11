from src.libs.custom_logger import get_custom_logger
import json
from urllib.parse import quote
from src.node.api_clients.base_client import BaseClient

logger = get_custom_logger(__name__)


class REST(BaseClient):
    def __init__(self, rest_port):
        self._rest_port = rest_port

    def rest_call(self, method, endpoint, payload=None):
        url = f"http://127.0.0.1:{self._rest_port}/{endpoint}"
        headers = {"Content-Type": "application/json"}
        return self.make_request(method, url, headers=headers, data=payload)

    def rest_call_text(self, method, endpoint, payload=None):
        url = f"http://127.0.0.1:{self._rest_port}/{endpoint}"
        headers = {"accept": "text/plain"}
        return self.make_request(method, url, headers=headers, data=payload)

    def info(self):
        info_response = self.rest_call("get", "debug/v1/info")
        return info_response.json()

    def health(self):
        health_response = self.rest_call("get", "health")
        return health_response.content

    def get_peers(self):
        get_peers_response = self.rest_call("get", "admin/v1/peers")
        return get_peers_response.json()

    def add_peers(self, peers):
        return self.rest_call("post", "admin/v1/peers", json.dumps(peers))

    def set_relay_subscriptions(self, pubsub_topics):
        return self.rest_call("post", "relay/v1/subscriptions", json.dumps(pubsub_topics))

    def set_relay_auto_subscriptions(self, content_topics):
        return self.rest_call("post", "relay/v1/auto/subscriptions", json.dumps(content_topics))

    def delete_relay_subscriptions(self, pubsub_topics):
        return self.rest_call("delete", "relay/v1/subscriptions", json.dumps(pubsub_topics))

    def delete_relay_auto_subscriptions(self, content_topics):
        return self.rest_call("delete", "relay/v1/auto/subscriptions", json.dumps(content_topics))

    def send_relay_message(self, message, pubsub_topic):
        return self.rest_call("post", f"relay/v1/messages/{quote(pubsub_topic, safe='')}", json.dumps(message))

    def send_relay_auto_message(self, message):
        return self.rest_call("post", "relay/v1/auto/messages", json.dumps(message))

    def send_light_push_message(self, payload):
        return self.rest_call("post", "lightpush/v3/message", json.dumps(payload))

    def get_relay_messages(self, pubsub_topic):
        get_messages_response = self.rest_call("get", f"relay/v1/messages/{quote(pubsub_topic, safe='')}")
        return get_messages_response.json()

    def get_relay_auto_messages(self, content_topic):
        get_messages_response = self.rest_call("get", f"relay/v1/auto/messages/{quote(content_topic, safe='')}")
        return get_messages_response.json()

    def set_filter_subscriptions(self, subscription):
        set_subscriptions_response = self.rest_call("post", "filter/v2/subscriptions", json.dumps(subscription))
        return set_subscriptions_response.json()

    def update_filter_subscriptions(self, subscription):
        update_subscriptions_response = self.rest_call("put", "filter/v2/subscriptions", json.dumps(subscription))
        return update_subscriptions_response.json()

    def delete_filter_subscriptions(self, subscription):
        delete_subscriptions_response = self.rest_call("delete", "filter/v2/subscriptions", json.dumps(subscription))
        return delete_subscriptions_response.json()

    def delete_all_filter_subscriptions(self, request_id):
        delete_all_subscriptions_response = self.rest_call("delete", "filter/v2/subscriptions/all", json.dumps(request_id))
        return delete_all_subscriptions_response.json()

    def ping_filter_subscriptions(self, request_id):
        ping_subscriptions_response = self.rest_call("get", f"filter/v2/subscriptions/{quote(request_id, safe='')}")
        return ping_subscriptions_response.json()

    def get_filter_messages(self, content_topic, pubsub_topic=None):
        if pubsub_topic is not None:
            endpoint = f"filter/v2/messages/{quote(pubsub_topic, safe='')}/{quote(content_topic, safe='')}"
        else:
            endpoint = f"filter/v2/messages/{quote(content_topic, safe='')}"
        get_messages_response = self.rest_call("get", endpoint)
        return get_messages_response.json()

    def get_store_messages(
        self,
        peer_addr,
        include_data,
        pubsub_topic,
        content_topics,
        start_time,
        end_time,
        hashes,
        cursor,
        page_size,
        ascending,
        store_v,
        encode_pubsubtopic=True,
        **kwargs,
    ):
        base_url = f"store/{store_v}/messages"
        params = []

        if peer_addr is not None:
            params.append(f"peerAddr={quote(peer_addr, safe='')}")
        if include_data is not None:
            params.append(f"includeData={include_data}")
        if pubsub_topic is not None:
            if encode_pubsubtopic:
                params.append(f"pubsubTopic={quote(pubsub_topic, safe='')}")
            else:
                params.append(f"pubsubTopic={pubsub_topic}")
        if content_topics is not None:
            params.append(f"contentTopics={quote(content_topics, safe='')}")
        if start_time is not None:
            params.append(f"startTime={start_time}")
        if end_time is not None:
            params.append(f"endTime={end_time}")
        if hashes is not None:
            params.append(f"hashes={quote(hashes, safe='')}")
        if cursor is not None:
            params.append(f"cursor={quote(cursor, safe='')}")
        if page_size is not None:
            params.append(f"pageSize={page_size}")
        if ascending is not None:
            params.append(f"ascending={ascending}")

        # Append any additional keyword arguments to the parameters list
        for key, value in kwargs.items():
            if value is not None:
                params.append(f"{key}={quote(str(value), safe='')}")

        if params:
            base_url += "?" + "&".join(params)

        get_messages_response = self.rest_call("get", base_url)
        return get_messages_response.json()

    def set_log_level(self, log_level):
        return self.rest_call("post", f"admin/v1/log-level/{quote(log_level)}")

    def get_service_peers(self):
        return self.rest_call("get", "admin/v1/peers/service").json()

    def get_connected_peers(self):
        return self.rest_call("get", "admin/v1/peers/connected").json()

    def get_connected_peers_on_shard(self, shard_id):
        return self.rest_call("get", f"admin/v1/peers/connected/on/{quote(str(shard_id))}").json()

    def get_relay_peers(self):
        return self.rest_call("get", "admin/v1/peers/relay").json()

    def get_relay_peers_on_shard(self, shard_id):
        return self.rest_call("get", f"admin/v1/peers/relay/on/{quote(str(shard_id))}").json()

    def get_mesh_peers(self):
        return self.rest_call("get", "admin/v1/peers/mesh").json()

    def get_mesh_peers_on_shard(self, shard_id):
        return self.rest_call("get", f"admin/v1/peers/mesh/on/{quote(str(shard_id))}").json()

    def get_peer_stats(self):
        return self.rest_call("get", "admin/v1/peers/stats").json()

    def get_filter_subscriptions(self):
        return self.rest_call("get", "admin/v1/filter/subscriptions").json()

    def get_info(self):
        return self.rest_call("get", "info").json()

    def get_version(self):
        return self.rest_call("get", "version").text.strip()

    def get_debug_version(self):
        return self.rest_call("get", "debug/v1/version").text.strip()

    def get_peer(self, peer_id: str):
        resp = self.rest_call("get", f"admin/v1/peer/{peer_id}")
        return resp.json()
