import os
import inspect
import random
import string

import pytest

from src.steps.common import StepsCommon
from src.test_data import PUBSUB_TOPICS_RLN
from src.env_vars import DEFAULT_NWAKU, RLN_CREDENTIALS, NODE_1, NODE_2, ADDITIONAL_NODES
from src.libs.common import gen_step_id, delay
from src.libs.custom_logger import get_custom_logger
from src.node.waku_node import WakuNode, rln_credential_store_ready

logger = get_custom_logger(__name__)


class StepsRLN(StepsCommon):
    test_pubsub_topic = PUBSUB_TOPICS_RLN[0]
    test_content_topic = "/test/1/waku-rln-relay/proto"
    test_payload = "RLN relay works!!"

    main_nodes = []
    optional_nodes = []
    multiaddr_list = []
    lightpush_nodes = []
    keystore_prefixes = []
    rln_membership_indexes = []

    def generate_keystore_prefixes(self, count=2):
        new_prefixes = []
        for _ in range(count):
            new_prefixes.append("".join(random.choices(string.ascii_lowercase, k=4)))

        return new_prefixes

    def register_rln_relay_nodes(self, count, orig_prefixes):
        if count > 0:
            self.keystore_prefixes = self.generate_keystore_prefixes(count)
            self.rln_membership_indexes = []
            for i, prefix in enumerate(self.keystore_prefixes):
                membership_index = self.register_rln_single_node(prefix=prefix, rln_creds_source=RLN_CREDENTIALS, rln_creds_id=f"{i+1}")
                self.rln_membership_indexes.append(membership_index)
        else:
            self.keystore_prefixes = orig_prefixes.get("keystore_prefixes", [])
            self.rln_membership_indexes = orig_prefixes.get("rln_membership_indexes", [])

        return {
            "keystore_prefixes": self.keystore_prefixes,
            "rln_membership_indexes": self.rln_membership_indexes,
        }

    def setup_main_rln_relay_nodes(self, **kwargs):
        self.setup_first_rln_relay_node(**kwargs)
        self.setup_second_rln_relay_node(**kwargs)

    def setup_first_rln_relay_node(self, **kwargs):
        self.node1 = WakuNode(NODE_1, f"node1_{self.test_id}")
        self.node1.start(
            relay="true",
            rln_creds_source=RLN_CREDENTIALS,
            rln_creds_id="1",
            rln_relay_membership_index=self.resolve_rln_membership_index(0, **kwargs),
            rln_keystore_prefix=self.keystore_prefixes[0],
            **kwargs,
        )
        self.enr_uri = self.node1.get_enr_uri()
        self.multiaddr_with_id = self.node1.get_multiaddr_with_id()
        self.main_nodes.extend([self.node1])

        self.multiaddr_list.extend([self.node1.get_multiaddr_with_id()])

    def setup_second_rln_relay_node(self, **kwargs):
        self.node2 = WakuNode(NODE_2, f"node2_{self.test_id}")
        self.node2.start(
            relay="true",
            discv5_bootstrap_node=self.enr_uri,
            rln_creds_source=RLN_CREDENTIALS,
            rln_creds_id="2",
            rln_relay_membership_index=self.resolve_rln_membership_index(1, **kwargs),
            rln_keystore_prefix=self.keystore_prefixes[1],
            **kwargs,
        )
        self.add_node_peer(self.node2, [self.multiaddr_with_id])
        self.main_nodes.extend([self.node2])

    def setup_optional_rln_relay_nodes(self, **kwargs):
        if ADDITIONAL_NODES:
            nodes = [node.strip() for node in ADDITIONAL_NODES.split(",")]
        else:
            pytest.skip("ADDITIONAL_NODES is empty, cannot run test")
        if len(nodes) > 3:
            logger.debug("More than 3 nodes are not supported for RLN tests, using first 3")
            nodes = nodes[:3]
        for index, node in enumerate(nodes):
            node = WakuNode(node, f"node{index + 3}_{self.test_id}")
            node.start(
                relay="true",
                discv5_bootstrap_node=self.enr_uri,
                rln_creds_source=RLN_CREDENTIALS,
                rln_creds_id=f"{index + 3}",
                rln_relay_membership_index=self.resolve_rln_membership_index(index + 2, **kwargs),
                rln_keystore_prefix=self.keystore_prefixes[index + 2],
                **kwargs,
            )
            self.add_node_peer(node, [self.multiaddr_with_id])
            self.optional_nodes.append(node)

    def setup_second_rln_lightpush_node(self, relay="true", **kwargs):
        self.light_push_node2 = WakuNode(NODE_2, f"lightpush_node2_{self.test_id}")
        self.light_push_node2.start(
            relay=relay,
            discv5_bootstrap_node=self.enr_uri,
            lightpush="true",
            lightpushnode=self.multiaddr_list[0],
            rln_creds_source=RLN_CREDENTIALS,
            rln_creds_id="2",
            rln_relay_membership_index=self.resolve_rln_membership_index(1, **kwargs),
            rln_keystore_prefix=self.keystore_prefixes[1],
            **kwargs,
        )
        if relay == "true":
            self.main_nodes.extend([self.light_push_node2])
        self.lightpush_nodes.extend([self.light_push_node2])
        self.add_node_peer(self.light_push_node2, self.multiaddr_list)

    def register_rln_single_node(self, prefix="", **kwargs):
        logger.debug("Registering RLN credentials for single node")
        self.node = WakuNode(DEFAULT_NWAKU, f"node_{gen_step_id()}")
        return self.node.register_rln(rln_keystore_prefix=prefix, rln_creds_source=kwargs["rln_creds_source"], rln_creds_id=kwargs["rln_creds_id"])

    def resolve_rln_membership_index(self, index, **kwargs):
        explicit_index = kwargs.get("rln_relay_membership_index")
        if explicit_index is not None:
            return str(explicit_index)

        if len(self.rln_membership_indexes) > index and self.rln_membership_indexes[index] is not None:
            inferred_index = str(self.rln_membership_indexes[index])
            logger.debug(f"Using inferred RLN membership index for position {index}: {inferred_index}")
            return inferred_index

        raise ValueError(
            f"RLN membership index for position {index} is not available. "
            "Register credentials and persist rln_membership_indexes together with keystore_prefixes before node startup."
        )

    def check_rln_registration(self, prefix, key_id):
        cwd = os.getcwd()
        creds_file_path = f"{cwd}/keystore_{prefix}_{key_id}/keystore.json"
        try:
            rln_credential_store_ready(creds_file_path)
        except Exception as ex:
            logger.error(f"Credentials at {creds_file_path} not available: {ex}")
            raise

    def publish_message(self, message=None, pubsub_topic=None, sender=None, use_lightpush=False):
        if message is None:
            message = self.create_message()
        if pubsub_topic is None:
            pubsub_topic = self.test_pubsub_topic
        if not sender:
            sender = self.node1

        if use_lightpush:
            payload = self.create_payload(pubsub_topic, message)
            sender.send_light_push_message(payload)
        else:
            sender.send_relay_message(message, pubsub_topic)

    def ensure_relay_subscriptions_on_nodes(self, node_list, pubsub_topic_list):
        for node in node_list:
            node.set_relay_subscriptions(pubsub_topic_list)

    def subscribe_main_relay_nodes(self):
        self.ensure_relay_subscriptions_on_nodes(self.main_nodes, [self.test_pubsub_topic])

    def subscribe_optional_relay_nodes(self):
        self.ensure_relay_subscriptions_on_nodes(self.optional_nodes, [self.test_pubsub_topic])

    def create_payload(self, pubsub_topic=None, message=None, **kwargs):
        if message is None:
            message = self.create_message()
        if pubsub_topic is None:
            pubsub_topic = self.test_pubsub_topic
        payload = {"pubsubTopic": pubsub_topic, "message": message}
        payload.update(kwargs)
        return payload
