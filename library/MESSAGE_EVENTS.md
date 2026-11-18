# Message Event Handling in LMAPI

## Overview

The liblogosdelivery library emits three types of message delivery events and one message receipt event that clients can listen to by registering a per-event callback with `logosdelivery_add_event_listener()`. The events are delivered under the wire names `onMessageSent`, `onMessagePropagated`, `onMessageError` and `onMessageReceived` (the JSON `eventType` inside each payload is `message_sent` / `message_propagated` / `message_error` / `message_received`).

`logosdelivery_ctx_send` returns the hash of the message as text, `0x` and 64 hex digits in lower case. Each delivery event of the send carries the same text in `messageHash`.

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
- `messageHash`: Hash that the send operation returned

### 2. message_propagated
Emitted when a message has been successfully propagated to neighboring nodes on the network.

**JSON Structure:**
```json
{
  "eventType": "message_propagated",
  "messageHash": "0x..."
}
```

**Fields:**
- `eventType`: Always "message_propagated"
- `messageHash`: Hash that the send operation returned

### 3. message_error
Emitted when a send that the send operation accepted fails: rejected, delivery window elapsed, no budget for a new RLN proof, or store validation timed out. The delivery window is 20 s from the timestamp of the message. After it, a Store node and an RLN relay validator refuse the message, so the node makes no more attempts.

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
- `messageHash`: Hash that the send operation returned
- `kind`: `NotPropagated` when the node knows of no propagation of the message. `NotStored` when the message propagated and no store node confirmed it in the validation window. The receivers can have a `NotStored` message. They can also have a `NotPropagated` message, when a mix exit or a lightpush service published it and its answer did not come.
- `error`: Description of what went wrong, for a person

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

For a refused message send:

1. **send** → Returns an error, and no event comes

The `on_reply` callback of `logosdelivery_ctx_send` gets the message hash before the event thread gets an event of that send.

## Send Errors

`logosdelivery_ctx_send` sets the timestamp of the message, so the message hash does not change after the call. It refuses a message that the node cannot accept. The error text is `Send failed: <description> (<kind>)`, for example `Send failed: node is not started (NotStarted)`. The kinds are:

- `NotStarted`: the node is not started.
- `NoShard`: the node finds no shard for the content topic of the message.
- `TooLarge`: the message is too large. With its RLN proof, it is above the `--max-msg-size` of the node. At the anonymity level `Required`, a message that one mix message cannot hold is also too large.
- `RateLimited`: the rate-limit budget of the epoch is spent. The description ends with `retry after <N> s`, and N is the seconds until the budget refills. With an RLN backend that does not state its epoch length, N is 1. An ephemeral message also gets this error when the budget is near its end. With RLN, the RLN budget also limits the sends.
- `QueueFull`: the node already has 50 sends that did not get their last event.
- `Duplicate`: the node already sends a message with this hash. Two sends of the same message get one hash only when the clock of the node gives them the same timestamp.

A text with no kind at its end is another fault.

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
