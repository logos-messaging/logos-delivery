# Message Event Handling in LMAPI

## Overview

The liblogosdelivery library emits three types of message delivery events and one message receipt event that clients can listen to by registering a per-event callback with `logosdelivery_add_event_listener()`. The events are delivered under the wire names `onMessageSent`, `onMessagePropagated`, `onMessageError` and `onMessageReceived` (the JSON `eventType` inside each payload is `message_sent` / `message_propagated` / `message_error` / `message_received`).

## Event Types

### 1. message_sent
Emitted when a message is successfully accepted by the send service and queued for delivery.

**JSON Structure:**
```json
{
  "eventType": "message_sent",
  "requestId": "unique-request-id",
  "messageHash": "0x..."
}
```

**Fields:**
- `eventType`: Always "message_sent"
- `requestId`: Request ID returned from the send operation
- `messageHash`: Hash of the message that was sent

### 2. message_propagated
Emitted when a message has been successfully propagated to neighboring nodes on the network.

**JSON Structure:**
```json
{
  "eventType": "message_propagated",
  "requestId": "unique-request-id",
  "messageHash": "0x..."
}
```

**Fields:**
- `eventType`: Always "message_propagated"
- `requestId`: Request ID from the send operation
- `messageHash`: Hash of the message that was propagated

### 3. message_error
Emitted when an error occurs during message sending or propagation.

**JSON Structure:**
```json
{
  "eventType": "message_error",
  "requestId": "unique-request-id",
  "messageHash": "0x...",
  "error": "error description"
}
```

**Fields:**
- `eventType`: Always "message_error"
- `requestId`: Request ID from the send operation
- `messageHash`: Hash of the message that failed
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

1. **send** → Returns request ID
2. **message_sent** → Message accepted and queued
3. **message_propagated** → Message delivered to peers

For a failed message send:

1. **send** → Returns request ID
2. **message_sent** → Message accepted and queued
3. **message_error** → Delivery failed with error description

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
