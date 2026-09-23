from dataclasses import dataclass, field
from marshmallow_dataclass import class_schema
from typing import Optional
import math
import allure


@dataclass
class MessageRpcResponse:
    payload: str
    contentTopic: str
    version: Optional[int]
    timestamp: Optional[int]
    ephemeral: Optional[bool]
    meta: Optional[str]
    proof: Optional[str] = field(default_factory=dict)
    rateLimitProof: Optional[str] = field(default_factory=dict)
    rate_limit_proof: Optional[dict] = field(default_factory=dict)


class WakuMessage:
    def __init__(self, message_response, schema=MessageRpcResponse):
        self.schema = schema
        self.received_messages = message_response
        self.message_rpc_response_schema = class_schema(self.schema)()

    @allure.step
    def assert_received_message(self, sent_message, index=0):
        message = self.message_rpc_response_schema.load(self.received_messages[index])

        def assert_fail_message(field_name):
            return f"Incorrect field: {field_name}. Published: {sent_message[field_name]} Received: {getattr(message, field_name)}"

        assert message.payload == sent_message["payload"], assert_fail_message("payload")
        assert message.contentTopic == sent_message["contentTopic"], assert_fail_message("contentTopic")
        if sent_message.get("timestamp") is not None:
            if isinstance(sent_message["timestamp"], float):
                assert math.isclose(float(message.timestamp), sent_message["timestamp"], rel_tol=1e-9), assert_fail_message("timestamp")
            else:
                assert str(message.timestamp) == str(sent_message["timestamp"]), assert_fail_message("timestamp")
        if "version" in sent_message:
            assert str(message.version) == str(sent_message["version"]), assert_fail_message("version")
        if "meta" in sent_message:
            assert str(message.meta) == str(sent_message["meta"]), assert_fail_message("meta")
        if "ephemeral" in sent_message:
            assert str(message.ephemeral) == str(sent_message["ephemeral"]), assert_fail_message("ephemeral")
