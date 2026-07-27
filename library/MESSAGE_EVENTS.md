# Message Event Handling in LMAPI

## Overview

The liblogosdelivery library emits events that clients receive by registering a
listener **per event name** with `logosdelivery_add_event_listener()`. There is
no catch-all callback: subscribe to each event you care about.

Every event payload is CBOR-encoded (RFC 8949) as the envelope

```
{"eventType": "<name>", "payload": { ...fields... }}
```

so a listener decodes the envelope, then reads the fields listed below out of
`payload`. `library/examples/cbor_helpers.c` provides the map-traversal
helpers (`cbor_find_in_map`, `cbor_borrow_tstr`, `cbor_borrow_bstr`) used
throughout the example.

## Event Types

### 1. message_sent
Emitted when a message is successfully accepted by the send service and queued for delivery.

**Payload fields:**
- `requestId` (text): Request ID returned from the send operation
- `messageHash` (text): Hash of the message that was sent

### 2. message_propagated
Emitted when a message has been successfully propagated to neighboring nodes on the network.

**Payload fields:**
- `requestId` (text): Request ID from the send operation
- `messageHash` (text): Hash of the message that was propagated

### 3. message_error
Emitted when an error occurs during message sending or propagation.

**Payload fields:**
- `requestId` (text): Request ID from the send operation
- `messageHash` (text): Hash of the message that failed
- `error` (text): Description of what went wrong

### 4. message_received
Emitted when a message arrives on a subscribed content topic.

**Payload fields:**
- `messageHash` (text): Hash of the received message
- `message` (map): the Waku message — `payload` (byte string), `contentTopic`
  (text), `meta` (byte string), `version` (uint), `timestamp` (int),
  `ephemeral` (bool), `proof` (byte string)

### Other events

The same envelope carries the node- and channel-level events:

| Event | Payload fields |
| --- | --- |
| `connection_status_change` | `connectionStatus` |
| `relay_topic_health_change` | `pubsubTopic`, `topicHealth` |
| `connection_change` | `peerId`, `peerEvent` |
| `channel_message_received` | `channelId`, `senderId`, `payload` (byte string) |
| `channel_message_sent` | `channelId`, `requestId` |
| `channel_message_error` | `channelId`, `requestId`, `error` |
| `message` | `pubsubTopic`, `messageHash`, `message` (kernel relay/filter push) |

## Usage

### 1. Define an Event Callback

```c
void event_callback(int ret, const char *msg, size_t len, void *userData) {
    if (ret != RET_OK || msg == NULL || len == 0) {
        return;
    }

    const uint8_t *buf = (const uint8_t *)msg;

    // Locate the payload map inside the envelope
    size_t scan = 0, payload_off = 0;
    if (cbor_find_in_map(buf, len, &scan, "payload", &payload_off) != 0) {
        return;
    }

    // Read a field out of it
    size_t cur = payload_off, value_off = 0;
    if (cbor_find_in_map(buf, len, &cur, "requestId", &value_off) != 0) {
        return;
    }
    const char *req = NULL;
    size_t req_len = 0;
    if (cbor_borrow_tstr(buf, len, &value_off, &req, &req_len) == 0) {
        printf("requestId: %.*s\n", (int)req_len, req);
    }
}
```

The listener already knows which event it is subscribed to, so reading
`eventType` back out of the envelope is only needed if one callback serves
several events.

### 2. Register the Listener

```c
void *ctx = logosdelivery_create_node(reqCbor, reqCborLen, callback, userData);
// ...wait for the create callback...
uint64_t id = logosdelivery_add_event_listener(ctx, "message_sent", event_callback, NULL);
```

Unregister with `logosdelivery_remove_event_listener(ctx, id)`.

### 3. Start the Node

Once the node is started, events will be delivered to your listeners:

```c
logosdelivery_start_node(ctx, callback, userData, reqCbor, reqCborLen);
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

1. **Thread Safety**: Listeners are invoked from the library's event thread.
   Ensure your callback is thread-safe if it accesses shared state.

2. **Non-Blocking**: Keep the callback fast and non-blocking. The event queue is
   bounded; a listener that blocks long enough to fill it makes the library
   reject new requests and fire `not_responding`.

3. **CBOR Parsing**: `cbor_helpers.c` covers the shapes these payloads use. For
   anything richer, use a full CBOR library such as
   [TinyCBOR](https://github.com/intel/tinycbor) or
   [libcbor](https://github.com/PJK/libcbor).

4. **Memory Management**: The message buffer is owned by the library and is only
   valid for the duration of the callback. Copy any data you need to retain —
   the borrow helpers point into that buffer.

5. **Event Order**: Events are delivered in the order they occur, but timing depends on network conditions.

## Example Implementation

See `library/examples/logosdelivery_example.c` for a complete working example that:
- Registers a listener per event name
- Sends a message
- Receives and prints the delivery events
- Decodes the CBOR envelope and payload fields

## Debugging Events

To see the raw bytes of an event during development:

```c
void debug_event_callback(int ret, const char *msg, size_t len, void *userData) {
    for (size_t i = 0; i < len; i++) {
        printf("%02x", (unsigned char)msg[i]);
    }
    printf("\n");
}
```

Decoding that hex dump (e.g. with <https://cbor.me>) shows the exact envelope
structure.
