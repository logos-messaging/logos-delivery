import json
import subprocess
import sys
import pytest
from src.steps.common import StepsCommon
from src.libs.common import to_base64
from src.node.wrappers_manager import WrapperManager
from src.node.wrapper_helpers import (
    EventCollector,
    assert_event_invariants,
    create_message_bindings,
    get_node_multiaddr,
    wait_for_connected,
    wait_for_propagated,
    wait_for_sent,
    wait_for_error,
)


PROPAGATED_TIMEOUT_S = 30.0

S01_EXPECTED_ERROR_FRAGMENT = "not initialized"
# Destroyed-handle path fails synchronously in the C layer (no callback),
# so the binding surfaces a different string than the nil-handle path.
S01_DESTROYED_HANDLE_ERROR_FRAGMENT = "immediate call failed"
S01_SUBPROCESS_TIMEOUT_S = 30
S01_RESULT_MARKER = "__S01_RESULT__"
SEND_AFTER_DESTROY_RESULT_MARKER = "__SEND_AFTER_DESTROY_RESULT__"
SEND_AFTER_DESTROY_SUBPROCESS_TIMEOUT_S = 60

S01_INVALID_HANDLE_HELPER = "tests.wrappers_tests.helpers.send_invalid_handle"

# S05: malformed content topics
S05_EXPECTED_ERROR_FRAGMENT = "Failed to auto-subscribe"
S05_MALFORMED_CONTENT_TOPICS = [
    # No leading slash — parser rejects with "must start with slash".
    ("s05-invalid-no-leading-slash", "no-leading-slash"),
    # Empty string — parser rejects empty content topic.
    ("", "empty"),
    # Only 3 segments — content topics need /app/version/name/encoding.
    ("/app/1/name", "missing-encoding-segment"),
    # Empty middle segment between slashes.
    ("/app//name/proto", "empty-middle-segment"),
]


class TestS01NilOrUninitializedHandle(StepsCommon):
    """S01 — send() on a nil/destroyed handle must Err, no events, no crash."""

    @pytest.mark.skip(reason="see https://github.com/logos-messaging/logos-delivery/issues/3873")
    def test_s01_send_on_uninitialized_handle(self):
        completed = subprocess.run(
            [sys.executable, "-m", S01_INVALID_HANDLE_HELPER, "nil", S01_RESULT_MARKER],
            capture_output=True,
            text=True,
            timeout=S01_SUBPROCESS_TIMEOUT_S,
        )

        assert completed.returncode == 0, (
            f"send() crashed on a nil handle (returncode={completed.returncode}). " f"stdout={completed.stdout!r} stderr={completed.stderr!r}"
        )

        result_line = next(
            (l for l in completed.stdout.splitlines() if l.startswith(S01_RESULT_MARKER)),
            None,
        )
        assert result_line, f"missing result marker. stdout={completed.stdout!r} stderr={completed.stderr!r}"

        result = json.loads(result_line[len(S01_RESULT_MARKER) :])

        assert result["is_ok"] is False, f"expected Err, got Ok({result['ok']!r})"
        assert S01_EXPECTED_ERROR_FRAGMENT in (
            result["err"] or ""
        ), f"expected error to mention {S01_EXPECTED_ERROR_FRAGMENT!r}, got: {result['err']!r}"

    @pytest.mark.skip(reason="see https://github.com/logos-messaging/logos-delivery/issues/3863")
    def test_s01_send_on_destroyed_handle(self):
        completed = subprocess.run(
            [sys.executable, "-m", S01_INVALID_HANDLE_HELPER, "destroyed", SEND_AFTER_DESTROY_RESULT_MARKER],
            capture_output=True,
            text=True,
            timeout=SEND_AFTER_DESTROY_SUBPROCESS_TIMEOUT_S,
        )

        assert completed.returncode == 0, (
            f"send() crashed on a destroyed handle (returncode={completed.returncode}). " f"stdout={completed.stdout!r} stderr={completed.stderr!r}"
        )

        result_line = next(
            (l for l in completed.stdout.splitlines() if l.startswith(SEND_AFTER_DESTROY_RESULT_MARKER)),
            None,
        )
        assert result_line, f"missing result marker. stdout={completed.stdout!r} stderr={completed.stderr!r}"

        result = json.loads(result_line[len(SEND_AFTER_DESTROY_RESULT_MARKER) :])

        assert result["stage"] == "send_message", f"setup failed at stage {result['stage']!r}: {result['err']!r}"
        assert result["is_ok"] is False, f"expected Err, got Ok({result['ok']!r})"
        err_msg = result["err"] or ""
        assert S01_EXPECTED_ERROR_FRAGMENT in err_msg or S01_DESTROYED_HANDLE_ERROR_FRAGMENT in err_msg, (
            f"expected error to mention {S01_EXPECTED_ERROR_FRAGMENT!r} " f"or {S01_DESTROYED_HANDLE_ERROR_FRAGMENT!r}, got: {result['err']!r}"
        )
        assert result["events_after_send"] == [], f"expected no events after send(), got: {result['events_after_send']}"


class TestS03SendOnAlreadySubscribedTopic(StepsCommon):
    """
    S03 — Send on already-subscribed content topic.
    Sender explicitly calls subscribe_content_topic() before send().
    The send path must behave identically to the auto-subscribe case:
    Propagated arrives, no Sent (store disabled), no Error.
    Topology mirrors S06 (relay-only sender + relay peer, no store).
    Purpose: proves the send path is identical when auto-subscription is skipped.
    """

    def test_s03_send_on_already_subscribed_content_topic(self, node_config):
        sender_collector = EventCollector()
        content_topic = "/test/1/s03-already-subscribed/proto"

        node_config.update(
            {
                "relay": True,
                "store": False,
                "lightpush": False,
                "filter": False,
                "discv5Discovery": False,
                "numShardsInNetwork": 1,
                "reliabilityEnabled": True,
            }
        )

        sender_result = WrapperManager.create_and_start(
            config=node_config,
            event_cb=sender_collector.event_callback,
        )
        assert sender_result.is_ok(), f"Failed to start sender: {sender_result.err()}"

        with sender_result.ok_value as sender:
            peer_config = {
                **node_config,
                "staticnodes": [get_node_multiaddr(sender)],
                "portsShift": 1,
            }

            peer_result = WrapperManager.create_and_start(config=peer_config)
            assert peer_result.is_ok(), f"Failed to start relay peer: {peer_result.err()}"

            with peer_result.ok_value:
                assert wait_for_connected(sender_collector) is not None, "Sender did not reach Connected/PartiallyConnected state"

                # Explicit subscribe before send — this is what S03 is about.
                # The send path must still return Ok(RequestId) and emit the
                # same events as the auto-subscribe topology in S06.
                subscribe_result = sender.subscribe_content_topic(content_topic)
                assert subscribe_result.is_ok(), f"subscribe_content_topic failed: {subscribe_result.err()}"

                message = create_message_bindings(
                    payload=to_base64("S03 already-subscribed test payload"),
                    contentTopic=content_topic,
                )

                send_result = sender.send_message(message=message)
                assert send_result.is_ok(), f"send() failed: {send_result.err()}"

                request_id = send_result.ok_value
                assert request_id, "send() returned an empty RequestId"

                propagated = wait_for_propagated(
                    collector=sender_collector,
                    request_id=request_id,
                    timeout_s=PROPAGATED_TIMEOUT_S,
                )
                assert propagated is not None, (
                    f"No message_propagated event within {PROPAGATED_TIMEOUT_S}s. " f"Collected events: {sender_collector.events}"
                )
                assert propagated["requestId"] == request_id

                error = wait_for_error(sender_collector, request_id, timeout_s=0)
                assert error is None, f"Unexpected message_error event: {error}"

                sent = wait_for_sent(sender_collector, request_id, timeout_s=0)
                assert sent is None, f"Unexpected message_sent event (store is disabled): {sent}"

                assert_event_invariants(sender_collector, request_id)


class TestS04UnsubscribeThenSendSameTopic(StepsCommon):
    """
    S04 — Unsubscribe, then send the same content topic again.
    Sender subscribes to topic A, unsubscribes from A, then sends on A.
    The send path must re-establish topic interest and deliver normally.
    Topology mirrors S06 (relay-only sender + relay peer, no store).
    Expected: send() returns Ok(RequestId), Propagated arrives,
    no Sent (store disabled), no Error.
    Purpose: verifies send() re-establishes topic interest after local unsubscribe.
    """

    def test_s04_unsubscribe_then_send_same_content_topic(self, node_config):
        sender_collector = EventCollector()
        content_topic = "/test/1/s04-unsubscribe-resend/proto"

        node_config.update(
            {
                "relay": True,
                "store": False,
                "lightpush": False,
                "filter": False,
                "discv5Discovery": False,
                "numShardsInNetwork": 1,
                "reliabilityEnabled": True,
            }
        )

        sender_result = WrapperManager.create_and_start(
            config=node_config,
            event_cb=sender_collector.event_callback,
        )
        assert sender_result.is_ok(), f"Failed to start sender: {sender_result.err()}"

        with sender_result.ok_value as sender:
            peer_config = {
                **node_config,
                "staticnodes": [get_node_multiaddr(sender)],
                "portsShift": 1,
            }

            peer_result = WrapperManager.create_and_start(config=peer_config)
            assert peer_result.is_ok(), f"Failed to start relay peer: {peer_result.err()}"

            with peer_result.ok_value:
                assert wait_for_connected(sender_collector) is not None, "Sender did not reach Connected/PartiallyConnected state"

                # subscribe -> unsubscribe -> send: send() must re-establish
                # topic interest internally.
                subscribe_result = sender.subscribe_content_topic(content_topic)
                assert subscribe_result.is_ok(), f"subscribe_content_topic failed: {subscribe_result.err()}"

                unsubscribe_result = sender.unsubscribe_content_topic(content_topic)
                assert unsubscribe_result.is_ok(), f"unsubscribe_content_topic failed: {unsubscribe_result.err()}"

                message = create_message_bindings(
                    payload=to_base64("S04 unsubscribe-then-send test payload"),
                    contentTopic=content_topic,
                )

                send_result = sender.send_message(message=message)
                assert send_result.is_ok(), f"send() failed after unsubscribe: {send_result.err()}"

                request_id = send_result.ok_value
                assert request_id, "send() returned an empty RequestId"

                propagated = wait_for_propagated(
                    collector=sender_collector,
                    request_id=request_id,
                    timeout_s=PROPAGATED_TIMEOUT_S,
                )
                assert propagated is not None, (
                    f"No message_propagated event within {PROPAGATED_TIMEOUT_S}s "
                    f"after unsubscribe + send. Collected events: {sender_collector.events}"
                )
                assert propagated["requestId"] == request_id

                error = wait_for_error(sender_collector, request_id, timeout_s=0)
                assert error is None, f"Unexpected message_error event: {error}"

                sent = wait_for_sent(sender_collector, request_id, timeout_s=0)
                assert sent is None, f"Unexpected message_sent event (store is disabled): {sent}"

                assert_event_invariants(sender_collector, request_id)


class TestS05AutoSubscribeFailureBeforeTaskCreation(StepsCommon):
    """
    S05 — Auto-subscribe failure before task creation.
    Sender is initialized but auto-subscription is forced to fail by using a
    malformed content topic that breaks shard resolution inside
    SubscriptionManager.subscribe().
    Expected: send() returns Err with an "auto-subscribe" message, no events.
    Purpose: covers the last synchronous error path before request ID creation,
    across several distinct validator branches.
    """

    @pytest.mark.parametrize(
        "content_topic",
        [topic for topic, _ in S05_MALFORMED_CONTENT_TOPICS],
        ids=[case_id for _, case_id in S05_MALFORMED_CONTENT_TOPICS],
    )
    def test_s05_send_fails_when_auto_subscribe_fails(self, node_config, content_topic):
        sender_collector = EventCollector()

        node_config.update(
            {
                "relay": True,
                "numShardsInNetwork": 1,
            }
        )

        sender_result = WrapperManager.create_and_start(
            config=node_config,
            event_cb=sender_collector.event_callback,
        )
        assert sender_result.is_ok(), f"Failed to start sender: {sender_result.err()}"

        with sender_result.ok_value as sender:
            # Malformed content topic — SubscriptionManager.subscribe() cannot
            # resolve it to a shard, so auto-subscribe inside send() fails.
            message = create_message_bindings(
                payload=to_base64("S05 auto-subscribe failure payload"),
                contentTopic=content_topic,
            )

            send_result = sender.send_message(message=message)

            assert send_result.is_err(), (
                f"send() must return Err when auto-subscribe fails for " f"content_topic={content_topic!r}, got Ok({send_result.ok_value!r})"
            )

            error_message = send_result.err() or ""
            assert S05_EXPECTED_ERROR_FRAGMENT in error_message, (
                f"expected error to mention {S05_EXPECTED_ERROR_FRAGMENT!r} " f"for content_topic={content_topic!r}, got: {error_message!r}"
            )

            # No request id was created, so no events should be emitted.
            assert sender_collector.events == [] or all(
                event.get("eventType") == "connection_status_change" for event in sender_collector.events
            ), f"Unexpected events after a pre-task-creation failure: {sender_collector.events}"
