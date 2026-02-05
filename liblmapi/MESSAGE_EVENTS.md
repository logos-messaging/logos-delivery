# Message Event Handling in LMAPI

## Overview

The LMAPI library emits three types of message delivery events that clients can listen to by registering an event callback using `lmapi_set_event_callback()`.

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
    }
}
```

### 2. Register the Callback

```c
void *ctx = lmapi_create_node(config, callback, userData);
lmapi_set_event_callback(ctx, event_callback, NULL);
```

### 3. Start the Node

Once the node is started, events will be delivered to your callback:

```c
lmapi_start_node(ctx, callback, userData);
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

1. **Thread Safety**: The event callback is invoked from the FFI worker thread. Ensure your callback is thread-safe if it accesses shared state.

2. **Non-Blocking**: Keep the callback fast and non-blocking. Do not perform long-running operations in the callback.

3. **JSON Parsing**: The example uses a simple string-based parser. For production, use a proper JSON library like:
   - [cJSON](https://github.com/DaveGamble/cJSON)
   - [json-c](https://github.com/json-c/json-c)
   - [Jansson](https://github.com/akheron/jansson)

4. **Memory Management**: The message buffer is owned by the library. Copy any data you need to retain.

5. **Event Order**: Events are delivered in the order they occur, but timing depends on network conditions.

## Example Implementation

See `examples/liblmapi_example.c` for a complete working example that:
- Registers an event callback
- Sends a message
- Receives and prints all three event types
- Properly parses the JSON event structure

## Debugging Events

To see all events during development:

```c
void debug_event_callback(int ret, const char *msg, size_t len, void *userData) {
    printf("Event received: %.*s\n", (int)len, msg);
}
```

This will print the raw JSON for all events, helping you understand the event structure.
