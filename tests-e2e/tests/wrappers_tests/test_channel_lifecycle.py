import pytest
from src.node.wrappers_manager import WrapperManager
from src.node.wrapper_helpers import EventCollector, create_message_bindings, unique_channel_id
from src.libs.common import delay

RC01_CHANNEL_PREFIX = "rc01-channel"
CONTENT_TOPIC = "/test/1/channel/proto"
SENDER_ID = "rc01-sender"

UNKNOWN_CHANNEL_PREFIX = "rc02-unknown-channel"

RC03_CHANNEL_PREFIX = "rc03-channel"
RC03_OPEN_CHANNEL_PREFIX = "rc03-open"
RC03_RANDOM_CHANNEL_PREFIX = "rc03-random"

RC04_CHANNEL_PREFIX = "rc04-channel"
RC04_CLOSED_CHANNEL_PREFIX = "rc04-closed-channel"
RC04_EPHEMERAL_CHANNEL_PREFIX = "rc04-ephemeral-channel"
RC04_DISTINCT_CHANNEL_PREFIX = "rc04-distinct-channel"

# Give the reliable channel manager a moment to settle a freshly-created
# channel before we act on it.
CHANNEL_SETTLE_S = 1


@pytest.mark.smoke
class TestChannelLifecycle:
    def test_rc01_create_channel_duplicate_rejected(self, node_config):
        """RC01: create a channel; a duplicate create with the same id is rejected.

        The reliable channel manager is mounted automatically for a Core-mode
        node, so no store / --reliability is needed. No events are expected.
        """
        # channel_create subscribes to its content topic, which needs autosharding.
        node_config.update({"mode": "Core", "numShardsInNetwork": 1})
        channel_id = unique_channel_id(RC01_CHANNEL_PREFIX)

        collector = EventCollector()
        create_node_result = WrapperManager.create_and_start(config=node_config, event_cb=collector.event_callback)
        assert create_node_result.is_ok(), f"Failed to create and start node: {create_node_result.err()}"
        node = create_node_result.ok_value

        try:
            create_result = node.channel_create(channel_id, CONTENT_TOPIC, SENDER_ID)
            assert create_result.is_ok(), f"channel_create failed: {create_result.err()}"
            assert create_result.ok_value == channel_id, f"channel_create returned unexpected id: {create_result.ok_value!r}"

            duplicate_result = node.channel_create(channel_id, CONTENT_TOPIC, SENDER_ID)
            assert duplicate_result.is_err(), f"duplicate channel_create must fail, got Ok({duplicate_result.ok_value!r})"
            assert f"channel already exists: {channel_id}" in duplicate_result.err(), f"unexpected error message: {duplicate_result.err()!r}"

            assert collector.events == [], f"expected no events, got: {collector.events}"
        finally:
            node.stop_and_destroy()

    def test_rc02_send_on_unknown_channel_rejected(self, node_config):
        """RC02: channel_send() to an id that was never created is rejected.

        The send must Err with "unknown channel: <id>" and emit no events.
        """
        node_config.update({"mode": "Core"})
        unknown_channel_id = unique_channel_id(UNKNOWN_CHANNEL_PREFIX)

        collector = EventCollector()
        create_node_result = WrapperManager.create_and_start(config=node_config, event_cb=collector.event_callback)
        assert create_node_result.is_ok(), f"Failed to create and start node: {create_node_result.err()}"
        node = create_node_result.ok_value

        try:
            send_result = node.channel_send(unknown_channel_id, create_message_bindings())
            assert send_result.is_err(), f"channel_send on unknown channel must fail, got Ok({send_result.ok_value!r})"
            assert f"unknown channel: {unknown_channel_id}" in send_result.err(), f"unexpected error message: {send_result.err()!r}"

            assert collector.events == [], f"expected no events, got: {collector.events}"
        finally:
            node.stop_and_destroy()

    def test_rc03_close_channel_close_unknown_rejected(self, node_config):
        """RC03: close an existing channel; closing again / an unknown id is rejected.

        First close succeeds; a second close of the same (now-gone) id and a
        close of a never-created id both Err with "unknown channel: <id>".
        Lifecycle teardown + idempotency guard. No events are expected.
        """
        node_config.update({"mode": "Core", "numShardsInNetwork": 1})
        channel_id = unique_channel_id(RC03_CHANNEL_PREFIX)
        unknown_channel_id = unique_channel_id(UNKNOWN_CHANNEL_PREFIX)

        collector = EventCollector()
        create_node_result = WrapperManager.create_and_start(config=node_config, event_cb=collector.event_callback)
        assert create_node_result.is_ok(), f"Failed to create and start node: {create_node_result.err()}"
        node = create_node_result.ok_value

        try:
            create_result = node.channel_create(channel_id, CONTENT_TOPIC, SENDER_ID)
            assert create_result.is_ok(), f"channel_create failed: {create_result.err()}"

            delay(CHANNEL_SETTLE_S)

            close_result = node.channel_close(channel_id)
            assert close_result.is_ok(), f"channel_close on an existing channel failed: {close_result.err()}"

            reclose_result = node.channel_close(channel_id)
            assert reclose_result.is_err(), f"second channel_close must fail, got Ok({reclose_result.ok_value!r})"
            assert f"unknown channel: {channel_id}" in reclose_result.err(), f"unexpected error message: {reclose_result.err()!r}"

            unknown_close_result = node.channel_close(unknown_channel_id)
            assert unknown_close_result.is_err(), f"channel_close on unknown channel must fail, got Ok({unknown_close_result.ok_value!r})"
            assert f"unknown channel: {unknown_channel_id}" in unknown_close_result.err(), f"unexpected error message: {unknown_close_result.err()!r}"

            assert collector.events == [], f"expected no events, got: {collector.events}"
        finally:
            node.stop_and_destroy()

    def test_rc03_close_random_id_leaves_open_channel_intact(self, node_config):
        """RC03 variant: closing a random unknown id while a real channel is open.

        A genuine channel is created and left open; closing a random id Errs with
        "unknown channel: <id>" and must not disturb the open channel, which then
        still closes cleanly. No events are expected.
        """
        node_config.update({"mode": "Core", "numShardsInNetwork": 1})

        channel_id = unique_channel_id(RC03_OPEN_CHANNEL_PREFIX)
        random_id = unique_channel_id(RC03_RANDOM_CHANNEL_PREFIX)

        collector = EventCollector()
        create_node_result = WrapperManager.create_and_start(config=node_config, event_cb=collector.event_callback)
        assert create_node_result.is_ok(), f"Failed to create and start node: {create_node_result.err()}"
        node = create_node_result.ok_value

        try:
            create_result = node.channel_create(channel_id, CONTENT_TOPIC, SENDER_ID)
            assert create_result.is_ok(), f"channel_create failed: {create_result.err()}"

            delay(CHANNEL_SETTLE_S)

            random_close_result = node.channel_close(random_id)
            assert random_close_result.is_err(), f"channel_close on a random id must fail, got Ok({random_close_result.ok_value!r})"
            assert f"unknown channel: {random_id}" in random_close_result.err(), f"unexpected error message: {random_close_result.err()!r}"

            # The real channel was left untouched and still closes cleanly.
            close_result = node.channel_close(channel_id)
            assert close_result.is_ok(), f"open channel_close failed after a bad-id close: {close_result.err()}"

            assert collector.events == [], f"expected no events, got: {collector.events}"
        finally:
            node.stop_and_destroy()

    def test_rc04_empty_payload_rejected_and_send_returns_handle(self, node_config):
        """RC04: empty payload is rejected; a non-empty send returns a handle synchronously.

        channel_send with an empty payload Errs with "empty payload"; a normal
        channel_send returns Ok(channelReqId) immediately (delivery is async).
        Input validation + the immediate-handle contract of send.
        """
        node_config.update({"mode": "Core", "numShardsInNetwork": 1})
        channel_id = unique_channel_id(RC04_CHANNEL_PREFIX)

        create_node_result = WrapperManager.create_and_start(config=node_config)
        assert create_node_result.is_ok(), f"Failed to create and start node: {create_node_result.err()}"
        node = create_node_result.ok_value

        try:
            create_result = node.channel_create(channel_id, CONTENT_TOPIC, SENDER_ID)
            assert create_result.is_ok(), f"channel_create failed: {create_result.err()}"

            delay(CHANNEL_SETTLE_S)

            empty_result = node.channel_send(channel_id, create_message_bindings(payload=""))
            assert empty_result.is_err(), f"channel_send with an empty payload must fail, got Ok({empty_result.ok_value!r})"
            assert "empty payload" in empty_result.err(), f"unexpected error message: {empty_result.err()!r}"

            send_result = node.channel_send(channel_id, create_message_bindings())
            assert send_result.is_ok(), f"channel_send with a non-empty payload failed: {send_result.err()}"
            assert send_result.ok_value, f"channel_send must return a non-empty channelReqId handle, got: {send_result.ok_value!r}"
        finally:
            node.stop_and_destroy()

    def test_rc04_send_after_close_rejected(self, node_config):
        """RC04 variant: sending after the channel is closed is rejected.

        Exercises the teardown -> send ordering (distinct from RC02's
        never-created id): once channel_close removes the id, channel_send Errs
        with "unknown channel: <id>". No events are expected.
        """
        node_config.update({"mode": "Core", "numShardsInNetwork": 1})
        channel_id = unique_channel_id(RC04_CLOSED_CHANNEL_PREFIX)

        collector = EventCollector()
        create_node_result = WrapperManager.create_and_start(config=node_config, event_cb=collector.event_callback)
        assert create_node_result.is_ok(), f"Failed to create and start node: {create_node_result.err()}"
        node = create_node_result.ok_value

        try:
            create_result = node.channel_create(channel_id, CONTENT_TOPIC, SENDER_ID)
            assert create_result.is_ok(), f"channel_create failed: {create_result.err()}"

            delay(CHANNEL_SETTLE_S)

            close_result = node.channel_close(channel_id)
            assert close_result.is_ok(), f"channel_close failed: {close_result.err()}"

            send_result = node.channel_send(channel_id, create_message_bindings())
            assert send_result.is_err(), f"channel_send after close must fail, got Ok({send_result.ok_value!r})"
            assert f"unknown channel: {channel_id}" in send_result.err(), f"unexpected error message: {send_result.err()!r}"

            assert collector.events == [], f"expected no events, got: {collector.events}"
        finally:
            node.stop_and_destroy()

    def test_rc04_ephemeral_send_returns_handle(self, node_config):
        """RC04 variant: an ephemeral channel_send still returns a handle synchronously.

        The ephemeral flag only affects downstream persistence / terminal events,
        not the send contract, so channel_send returns Ok(channelReqId) immediately.
        """
        node_config.update({"mode": "Core", "numShardsInNetwork": 1})
        channel_id = unique_channel_id(RC04_EPHEMERAL_CHANNEL_PREFIX)

        create_node_result = WrapperManager.create_and_start(config=node_config)
        assert create_node_result.is_ok(), f"Failed to create and start node: {create_node_result.err()}"
        node = create_node_result.ok_value

        try:
            create_result = node.channel_create(channel_id, CONTENT_TOPIC, SENDER_ID)
            assert create_result.is_ok(), f"channel_create failed: {create_result.err()}"

            delay(CHANNEL_SETTLE_S)

            send_result = node.channel_send(channel_id, create_message_bindings(ephemeral=True))
            assert send_result.is_ok(), f"ephemeral channel_send failed: {send_result.err()}"
            assert send_result.ok_value, f"channel_send must return a non-empty channelReqId handle, got: {send_result.ok_value!r}"
        finally:
            node.stop_and_destroy()

    def test_rc04_sequential_sends_return_distinct_handles(self, node_config):
        """RC04 variant: back-to-back sends each return a distinct handle.

        Every channel_send is its own request, so two sends on the same channel
        return two different (non-empty) channelReqId handles.
        """
        node_config.update({"mode": "Core", "numShardsInNetwork": 1})
        channel_id = unique_channel_id(RC04_DISTINCT_CHANNEL_PREFIX)

        create_node_result = WrapperManager.create_and_start(config=node_config)
        assert create_node_result.is_ok(), f"Failed to create and start node: {create_node_result.err()}"
        node = create_node_result.ok_value

        try:
            create_result = node.channel_create(channel_id, CONTENT_TOPIC, SENDER_ID)
            assert create_result.is_ok(), f"channel_create failed: {create_result.err()}"

            delay(CHANNEL_SETTLE_S)

            first_result = node.channel_send(channel_id, create_message_bindings())
            assert first_result.is_ok(), f"first channel_send failed: {first_result.err()}"
            assert first_result.ok_value, f"first channel_send returned an empty handle: {first_result.ok_value!r}"

            second_result = node.channel_send(channel_id, create_message_bindings())
            assert second_result.is_ok(), f"second channel_send failed: {second_result.err()}"
            assert second_result.ok_value, f"second channel_send returned an empty handle: {second_result.ok_value!r}"

            assert (
                first_result.ok_value != second_result.ok_value
            ), f"channel_send handles must be distinct, got the same id twice: {first_result.ok_value!r}"
        finally:
            node.stop_and_destroy()
