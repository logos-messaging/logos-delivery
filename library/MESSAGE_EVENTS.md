# Message Event Handling in LMAPI

## Overview

The liblogosdelivery library emits three types of message delivery events and one message receipt event that clients can listen to by registering a per-event callback with `logosdelivery_add_event_listener()`. The events are delivered under the wire names `onMessageSent`, `onMessagePropagated`, `onMessageError` and `onMessageReceived` (the JSON `eventType` inside each payload is `message_sent` / `message_propagated` / `message_error` / `message_received`).

## The result of a send

`logosdelivery_ctx_send` answers with the `0x` hex hash of the message. The hash is final: `send` stamps the message, so the hash never changes, and it keys every delivery event of the message.

`send` refuses a message at once, with no event, when:

| Kind | When |
| --- | --- |
| `NotStarted` | The node is not started. |
| `NotConnected` | The node has no connected peer, and knows no lightpush peer for the shard of the message. |
| `NoShard` | The content topic maps to no shard of the node. |
| `Duplicate` | A message with the same hash is still in flight. |
| `QueueFull` | The node already has 200 sends with no last event. |
| `RateLimited` | The rate-limit budget of the epoch is spent. The text gives the seconds until the next epoch, or 1 s when the RLN backend does not state the length of its epoch. |
| `TooLarge` | The message, with its RLN proof, exceeds the maximum message size. |

The text of a refusal ends with its kind in parentheses, for example `the rate-limit budget of the epoch is spent, retry after 42 s (RateLimited)`. Nothing is queued for a refused message; the app decides whether to send it again.

## Event Types

### 1. message_sent
Emitted when the node confirms the delivery of a message that is not ephemeral, with the `reliability` option on. For a normal send, a store node confirms the delivery. For a send over mix, the reply of the mix exit confirms it. For an ephemeral message, or with the `reliability` option off, `message_sent` does not come, and a successful send ends at `message_propagated`.

**JSON Structure:**
```json
{
  "eventType": "message_sent",
  "messageHash": "0x..."
}
```

**Fields:**
- `eventType`: Always "message_sent"
- `messageHash`: Hash of the message, as returned by the send operation

### 2. message_propagated
Emitted when a message has been successfully propagated to neighboring nodes on the network, by an attempt that started within 15 s of the send.

**JSON Structure:**
```json
{
  "eventType": "message_propagated",
  "messageHash": "0x..."
}
```

**Fields:**
- `eventType`: Always "message_propagated"
- `messageHash`: Hash of the message, as returned by the send operation

### 3. message_error
Emitted when a message that `send` accepted fails. `kind` tells the two cases apart:

- `NotPropagated`: no peer took the message within 15 s of the send, or a peer rejected it for a reason that a retry cannot clear. Retries, the mix to plain fallback of `Preferred` and the resends after a Store miss all start within these 15 s, because Store and RLN validators refuse a message more than 20 s off their clock.
- `NotStored`: the message propagated, but no store node reported it within the store validation window.

**JSON Structure:**
```json
{
  "eventType": "message_error",
  "messageHash": "0x...",
  "kind": "NotPropagated",
  "error": "error description"
}
```

**Fields:**
- `eventType`: Always "message_error"
- `messageHash`: Hash of the message, as returned by the send operation
- `kind`: `NotPropagated` or `NotStored`
- `error`: Description of what went wrong

### 4. message_received
Emitted once for every message accepted on a subscribed content topic, whether it arrived live from the network or was recovered from a Store peer (at startup, or after a connectivity gap). The `source` field tells the two apart.

**JSON Structure:**
```json
{
  "eventType": "message_received",
  "messageHash": "0x...",
  "message": {
    "payload": "base64...",
    "contentTopic": "/myapp/1/chat/proto",
    "version": 0,
    "timestamp": 1700000000000000000,
    "ephemeral": false,
    "meta": "",
    "proof": ""
  },
  "source": "live"
}
```

**Fields:**
- `eventType`: Always "message_received"
- `messageHash`: Hash of the received message
- `message`: The received message; `payload`, `meta` and `proof` are base64-encoded
- `source`: `"live"` when the message was delivered as it was published (relay or filter), `"history"` when it was recovered from Store

Duplicate suppression is best effort. The node remembers the hashes it has delivered for a few minutes, in memory only, so a live message that a Store check returns within that window is not reported again. After a restart, or when a Store recovery returns a message later than that, the same message can be reported a second time as `history`. Consumers that need exactly-once delivery should deduplicate by `messageHash`.

## Usage

### 1. Define an Event Callback

```c
void event_callback(int ret, const char *msg, size_t len, void *userData) {
    if (ret != RET_OK || msg == NULL || len == 0) {
        return;
    }

    // Parse the JSON message
    // Extract eventType field
    // Handle based on event type

    if (eventType == "message_sent") {
        // Handle message sent
    } else if (eventType == "message_propagated") {
        // Handle message propagated
    } else if (eventType == "message_error") {
        // Handle message error
    } else if (eventType == "message_received") {
        // Handle message received; check "source" for "live" or "history"
    }
}
```

### 2. Register the Callback

Register the callback once per event name you want to receive. Each call returns a
listener id you can later pass to `logosdelivery_remove_event_listener(rawCtx, id)`.

The event API takes the raw context, which is the `ptr` field of the
`LogosDeliveryCtx` that `logosdelivery_ctx_create` hands to its callback.

```c
// ctx comes from the logosdelivery_ctx_create callback; see the README.
void *rawCtx = ctx->ptr;
logosdelivery_add_event_listener(rawCtx, "onMessageSent", event_callback, NULL);
logosdelivery_add_event_listener(rawCtx, "onMessagePropagated", event_callback, NULL);
logosdelivery_add_event_listener(rawCtx, "onMessageError", event_callback, NULL);
logosdelivery_add_event_listener(rawCtx, "onMessageReceived", event_callback, NULL);
```

### 3. Start the Node

Once the node is started, events will be delivered to your callback:

```c
logosdelivery_ctx_start_node(ctx, on_reply, userData);
```

## Event Flow

For a typical successful message send:

1. **send** → Returns the message hash
2. **message_propagated** → Message delivered to peers
3. **message_sent** → A store node or the mix exit confirms the message (only with the `reliability` option on)

For a failed message send:

1. **send** → Returns the message hash
2. **message_error** → Delivery failed with error description

For a send that no store node confirms (only with the `reliability` option on):

1. **send** → Returns the message hash
2. **message_propagated** → Message delivered to peers
3. **message_error** → No store node confirmed the message within the validation window

The `on_reply` callback of `logosdelivery_ctx_send` gets the message hash before the event thread gets an event of that message. A refused send returns an error and no hash, and gets no event. A send of a message that is still in flight is refused as `Duplicate`.

## Important Notes

1. **Thread Safety**: The event callback is invoked from a dedicated event thread (separate from the FFI worker thread). Ensure your callback is thread-safe if it accesses shared state.

2. **Non-Blocking**: Keep the callback fast and non-blocking. Do not perform long-running operations in the callback.

3. **JSON Parsing**: The example uses a simple string-based parser. For production, use a proper JSON library like:
   - [cJSON](https://github.com/DaveGamble/cJSON)
   - [json-c](https://github.com/json-c/json-c)
   - [Jansson](https://github.com/akheron/jansson)

4. **Memory Management**: The message buffer is owned by the library. Copy any data you need to retain.

5. **Event Order**: Events are delivered in the order they occur, but timing depends on network conditions.

## Example Implementation

See `examples/liblogosdelivery_example.c` for a complete working example that:
- Registers an event callback
- Sends a message
- Receives and prints all four event types
- Properly parses the JSON event structure

## Debugging Events

To see all events during development:

```c
void debug_event_callback(int ret, const char *msg, size_t len, void *userData) {
    printf("Event received: %.*s\n", (int)len, msg);
}
```

This will print the raw JSON for all events, helping you understand the event structure.
