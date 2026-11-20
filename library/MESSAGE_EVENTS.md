# Message Event Handling in LMAPI

## Overview

The liblogosdelivery library emits four types of message delivery events, one message receipt event and three history query events that clients can listen to by registering a per-event callback with `logosdelivery_add_event_listener()`. The events are delivered under the wire names `onMessageQueued`, `onMessageSent`, `onMessagePropagated`, `onMessageError`, `onMessageReceived`, `onHistoryQueryMessage`, `onHistoryQueryCompleted` and `onHistoryQueryError` (the JSON `eventType` inside each payload is `message_queued` / `message_sent` / `message_propagated` / `message_error` / `message_received` / `history_query_message` / `history_query_completed` / `history_query_error`).

## Event Types

### 1. message_sent
Emitted when the node confirms the delivery of a message that is not ephemeral, with the `reliability` option on. For a normal send, a store node confirms the delivery. For a send over mix, the reply of the mix exit confirms it. For an ephemeral message, or with the `reliability` option off, `message_sent` does not come, and a successful send ends at `message_propagated`.

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
Emitted when a send fails: rejected, retry window elapsed, parked too long, ephemeral dropped near the rate limit, or store validation timed out.

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

### 4. message_queued
Emitted when a send is held back because the current epoch's rate-limit budget is spent. The message is not rejected: it stays queued and goes out once the budget refills. Emitted at most once per send, on the first time the message is held back.

**JSON Structure:**
```json
{
  "eventType": "message_queued",
  "requestId": "unique-request-id",
  "messageHash": "0x..."
}
```

**Fields:**
- `eventType`: Always "message_queued"
- `requestId`: Request ID from the send operation
- `messageHash`: Hash of the message that was held back

### 5. message_received
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

### 6. history_query_message
Emitted once for each message that a history query finds. A history query starts with `logosdelivery_ctx_query_history`, and its content topic doesn't need a subscription. The messages can come out of timestamp order.

**JSON Structure:**
```json
{
  "eventType": "history_query_message",
  "requestId": "unique-request-id",
  "messageHash": "0x...",
  "message": {
    "payload": "base64...",
    "contentTopic": "/myapp/1/chat/proto",
    "version": 0,
    "timestamp": 1700000000000000000,
    "ephemeral": false,
    "meta": "",
    "proof": ""
  }
}
```

**Fields:**
- `eventType`: Always "history_query_message"
- `requestId`: Request ID from `logosdelivery_ctx_query_history`
- `messageHash`: Hash of the message
- `message`: The message, with `payload`, `meta` and `proof` base64-encoded

The node doesn't check these messages against the `message_received` events, so the same message can come in both events, and in two queries. Use `messageHash` to find a message that you already have.

### 7. history_query_completed
Emitted when a history query completes, after its last `history_query_message` event.

**JSON Structure:**
```json
{
  "eventType": "history_query_completed",
  "requestId": "unique-request-id",
  "messageCount": 3
}
```

**Fields:**
- `eventType`: Always "history_query_completed"
- `requestId`: Request ID from `logosdelivery_ctx_query_history`
- `messageCount`: The number of messages that the query found

### 8. history_query_error
Emitted when a history query fails, for example when no Store node gives a page after the last try. It is the last event of the query.

**JSON Structure:**
```json
{
  "eventType": "history_query_error",
  "requestId": "unique-request-id",
  "error": "error description"
}
```

**Fields:**
- `eventType`: Always "history_query_error"
- `requestId`: Request ID from `logosdelivery_ctx_query_history`
- `error`: Description of what went wrong

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

    if (eventType == "message_queued") {
        // Handle message held back for rate-limit budget
    } else if (eventType == "message_sent") {
        // Handle message sent
    } else if (eventType == "message_propagated") {
        // Handle message propagated
    } else if (eventType == "message_error") {
        // Handle message error
    } else if (eventType == "message_received") {
        // Handle message received; check "source" for "live" or "history"
    } else if (eventType == "history_query_message") {
        // Handle a message that a history query found
    } else if (eventType == "history_query_completed") {
        // Handle the end of a history query
    } else if (eventType == "history_query_error") {
        // Handle a history query that stopped with an error
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
logosdelivery_add_event_listener(rawCtx, "onMessageQueued", event_callback, NULL);
logosdelivery_add_event_listener(rawCtx, "onMessageSent", event_callback, NULL);
logosdelivery_add_event_listener(rawCtx, "onMessagePropagated", event_callback, NULL);
logosdelivery_add_event_listener(rawCtx, "onMessageError", event_callback, NULL);
logosdelivery_add_event_listener(rawCtx, "onMessageReceived", event_callback, NULL);
logosdelivery_add_event_listener(rawCtx, "onHistoryQueryMessage", event_callback, NULL);
logosdelivery_add_event_listener(rawCtx, "onHistoryQueryCompleted", event_callback, NULL);
logosdelivery_add_event_listener(rawCtx, "onHistoryQueryError", event_callback, NULL);
```

### 3. Start the Node

Once the node is started, events will be delivered to your callback:

```c
logosdelivery_ctx_start_node(ctx, on_reply, userData);
```

## Event Flow

For a typical successful message send:

1. **send** → Returns request ID
2. **message_propagated** → Message delivered to peers
3. **message_sent** → A store node or the mix exit confirms the message (only with the `reliability` option on)

For a failed message send:

1. **send** → Returns request ID
2. **message_error** → Delivery failed with error description

For a send that no store node confirms (only with the `reliability` option on):

1. **send** → Returns request ID
2. **message_propagated** → Message delivered to peers
3. **message_error** → No store node confirmed the message within the validation window

For a history query:

1. **query_history** → Returns request ID
2. **history_query_message** → Once for each message that the query finds
3. **history_query_completed** → The query completed

For a failed history query:

1. **query_history** → Returns request ID
2. **history_query_message** → Once for each message that the query found before the error
3. **history_query_error** → The query stopped with an error

At this time, the node gets the history from Store nodes. Each page comes from one Store node, so a page can miss a message that only another Store node has. A Store node can get a message late, so when the range of a query ends after the call or a short time before it, the node gets the last part of the range again later. Such a query completes some time after the call, and later when many queries are active.

A stop of the node cancels its queries, and they emit no more events. The next start doesn't run them again.

The `on_reply` callback of `logosdelivery_ctx_send` or of `logosdelivery_ctx_query_history` gets the request ID before the event thread gets an event of that request. When the send queue is full, `logosdelivery_ctx_send` returns an error and no request ID. A send of a message that the send queue already has gets the request ID of the queued send.

## Important Notes

1. **Thread Safety**: The event callback is invoked from a dedicated event thread (separate from the FFI worker thread). Ensure your callback is thread-safe if it accesses shared state.

2. **Non-Blocking**: Keep the callback fast and non-blocking. Do not perform long-running operations in the callback.

3. **JSON Parsing**: The example uses a simple string-based parser. For production, use a proper JSON library like:
   - [cJSON](https://github.com/DaveGamble/cJSON)
   - [json-c](https://github.com/json-c/json-c)
   - [Jansson](https://github.com/akheron/jansson)

4. **Memory Management**: The message buffer is owned by the library. Copy any data you need to retain.

5. **Event Order**: Events are delivered in the order they occur, but timing depends on network conditions.

6. **Event Queue**: The library keeps a limited number of events for the callback in a queue. When the queue is full, the library drops every new event of any type, also a `message_received` event and the last event of a history query. After the first dropped event, the library rejects every new request, also `logosdelivery_ctx_stop_node`. Only `logosdelivery_ctx_destroy` can still stop the node, so destroy the context and create a new one. A history query can give many events in a short time, so copy each event in the callback and return at once.

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
