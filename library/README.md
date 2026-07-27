# Logos Messaging API (LMAPI) Library

A C FFI library providing a simplified interface to Logos Messaging functionality.

## Overview

This library wraps the high-level API functions from `waku/api/api.nim` and exposes them via a C FFI interface, making them accessible from C, C++, and other languages that support C FFI.

## Wire format

Since nim-ffi 0.2 the FFI boundary speaks CBOR (RFC 8949):

- **Requests** are a CBOR map whose keys are the Nim-side parameter names,
  listed with each function below. A function with no parameters takes the
  placeholder map `{"_placeholder": 0}`.
- **Successful responses** arrive in the callback as a CBOR-encoded value; for
  every function here that is a CBOR text string.
- **Errors** arrive as raw UTF-8, *not* CBOR.
- **Events** are a CBOR map `{"eventType": <name>, "payload": <body>}`.

`library/examples/cbor_helpers.c` implements the small encoder/decoder subset
this ABI needs, and `library/examples/logosdelivery_example.c` shows it in use.

## API Functions

### Node Lifecycle

#### `logosdelivery_create_node`
Creates a new instance of the node from the given configuration JSON.

```c
void *logosdelivery_create_node(
    const uint8_t *reqCbor,
    size_t reqCborLen,
    FFICallBack callback,
    void *userData
);
```

**Parameters:**
- `reqCbor` / `reqCborLen`: CBOR map `{"configJson": "<json>"}`
- `callback`: Callback function to receive the result
- `userData`: User data passed to the callback

**Returns:** Pointer to the context needed by other API functions, or NULL on
error. Node initialization is asynchronous: the callback fires later with the
context address on success, or the failure reason on error. Wait for it before
issuing further calls.

**Example configuration JSON:**
```json
{
  "mode": "Core",
  "preset": "logos.dev",
  "messagingOverrides": {
    "listen-address": "0.0.0.0",
    "tcp-port": 60000,
    "discv5-udp-port": 9000
  }
}
```

The configuration object has four optional top-level keys: `mode` (`"Core"` or
`"Edge"`, defaults to `"Core"`), `preset`, `messagingOverrides` (per-field node
config overrides), and `channelsOverrides` (reliable-channel overrides).
Override keys accept the config field name or its CLI switch name (e.g.
`"clusterId"` or `"cluster-id"`); unknown keys are rejected.
Use `"preset"` to select a network preset (e.g., `"twn"`, `"logos.dev"`,
`"status.prod"`) which auto-configures entry nodes, cluster ID, sharding, and
other network-specific settings.

Available presets:

| Preset | Cluster ID | RLN | Sharding | Network |
| --- | --- | --- | --- | --- |
| `twn` | 1 | on | auto (8 shards) | The Waku Network |
| `logos.dev` | 2 | off | auto (8 shards) | Logos Dev Network |
| `logos.test` | 2 | off | auto (8 shards) | Logos Test Network |
| `status.prod` | 16 | off | auto (1 shard) | Status Production Network |

#### `logosdelivery_start_node`
Starts the node.

```c
int logosdelivery_start_node(
    void *ctx,
    FFICallBack callback,
    void *userData,
    const uint8_t *reqCbor,
    size_t reqCborLen
);
```

Request: `{}` (placeholder map).

#### `logosdelivery_stop_node`
Stops the node.

```c
int logosdelivery_stop_node(
    void *ctx,
    FFICallBack callback,
    void *userData,
    const uint8_t *reqCbor,
    size_t reqCborLen
);
```

Request: `{}` (placeholder map).

#### `logosdelivery_destroy`
Destroys a node instance and returns its slot to the context pool. Stop the
node first. This one is synchronous — it takes no callback and no request
buffer, and reports the outcome through its return code.

```c
int logosdelivery_destroy(void *ctx);
```

### Messaging

#### `logosdelivery_subscribe`
Subscribe to a content topic to receive messages.

```c
int logosdelivery_subscribe(
    void *ctx,
    FFICallBack callback,
    void *userData,
    const uint8_t *reqCbor,
    size_t reqCborLen
);
```

**Parameters:**
- `ctx`: Context pointer from `logosdelivery_create_node`
- `callback`: Callback function to receive the result
- `userData`: User data passed to the callback
- `reqCbor` / `reqCborLen`: CBOR map `{"contentTopic": "/myapp/1/chat/proto"}`

#### `logosdelivery_unsubscribe`
Unsubscribe from a content topic.

```c
int logosdelivery_unsubscribe(
    void *ctx,
    FFICallBack callback,
    void *userData,
    const uint8_t *reqCbor,
    size_t reqCborLen
);
```

Request: `{"contentTopic": "/myapp/1/chat/proto"}`.

#### `logosdelivery_send`
Send a message.

```c
int logosdelivery_send(
    void *ctx,
    FFICallBack callback,
    void *userData,
    const uint8_t *reqCbor,
    size_t reqCborLen
);
```

**Parameters:**
- `reqCbor` / `reqCborLen`: CBOR map `{"messageJson": "<json>"}`

**Example message JSON:**
```json
{
  "contentTopic": "/myapp/1/chat/proto",
  "payload": "SGVsbG8gV29ybGQ=",
  "ephemeral": false
}
```

Note: The `payload` field should be base64-encoded.

**Returns:** Request ID in the callback message that can be used to track message delivery.

### Events

Listeners are registered per event name; there is no single catch-all callback.

#### `logosdelivery_add_event_listener`
Registers `callback` for one event name and returns its listener id (`0` on a
bad context or callback). Subscribe to each event you care about.

```c
uint64_t logosdelivery_add_event_listener(
    void *ctx,
    const char *eventName,
    FFICallBack callback,
    void *userData
);
```

**Important:** The callback runs on the library's event thread, so it should be
fast, non-blocking, and thread-safe.

#### `logosdelivery_remove_event_listener`
Unregisters a listener by id. Returns `RET_OK` (0), or non-zero if no listener
with that id exists.

```c
int logosdelivery_remove_event_listener(void *ctx, uint64_t listenerId);
```

See [MESSAGE_EVENTS.md](MESSAGE_EVENTS.md) for the event names and payloads.

## Building

The library follows the same build system as the main Logos Messaging project.

### Build the library

```bash
make liblogosdeliveryStatic    # Build static library
# or
make liblogosdeliveryDynamic   # Build dynamic library
```

## Return Codes

All functions that return `int` use the following return codes:

- `RET_OK` (0): Success
- `RET_ERR` (1): Error
- `RET_MISSING_CALLBACK` (2): Missing callback function

## Callback Function

All API functions use the following callback signature:

```c
typedef void (*FFICallBack)(
    int callerRet,
    const char *msg,
    size_t len,
    void *userData
);
```

**Parameters:**
- `callerRet`: Return code (RET_OK, RET_ERR, etc.)
- `msg`: Response message (may be empty for success)
- `len`: Length of the message
- `userData`: User data passed in the original call

## Example Usage

```c
#include "liblogosdelivery.h"
#include "cbor_helpers.h"
#include <stdio.h>
#include <stdlib.h>

void callback(int ret, const char *msg, size_t len, void *userData) {
    if (ret == RET_OK) {
        // Success payloads are CBOR; errors are raw text.
        char out[4096];
        size_t out_len = 0;
        if (cbor_decode_tstr((const uint8_t *)msg, len, out, sizeof(out), &out_len) == 0) {
            printf("Success: %s\n", out);
        } else {
            printf("Success\n");
        }
    } else {
        printf("Error: %.*s\n", (int)len, msg);
    }
}

// Encodes {"<key>": "<val>"} and issues the call.
static void call_kv(int (*fn)(void *, FFICallBack, void *, const uint8_t *, size_t),
                    void *ctx, const char *key, const char *val) {
    size_t len = 0;
    const size_t cap = cbor_size_map1_tstr_tstr(key, val);
    uint8_t *req = malloc(cap);
    if (!req || cbor_encode_map1_tstr_tstr(req, cap, key, val, &len) != 0) {
        free(req);
        return;
    }
    fn(ctx, callback, NULL, req, len);
    free(req);
}

int main() {
    const char *config = "{"
        "\"mode\": \"Core\","
        "\"preset\": \"logos.dev\""
        "}";

    // Create node
    size_t req_len = 0;
    const size_t cap = cbor_size_map1_tstr_tstr("configJson", config);
    uint8_t *req = malloc(cap);
    cbor_encode_map1_tstr_tstr(req, cap, "configJson", config, &req_len);
    void *ctx = logosdelivery_create_node(req, req_len, callback, NULL);
    free(req);
    if (ctx == NULL) {
        return 1;
    }
    // ...wait for the create callback before continuing...

    // Listen for delivery confirmations
    logosdelivery_add_event_listener(ctx, "message_sent", callback, NULL);

    // Start node (no parameters -> placeholder map)
    size_t empty_len = 0;
    uint8_t empty[16];
    cbor_encode_map1_placeholder(empty, sizeof(empty), &empty_len);
    logosdelivery_start_node(ctx, callback, NULL, empty, empty_len);

    // Subscribe to a topic
    call_kv(logosdelivery_subscribe, ctx, "contentTopic", "/myapp/1/chat/proto");

    // Send a message
    const char *msg = "{"
        "\"contentTopic\": \"/myapp/1/chat/proto\","
        "\"payload\": \"SGVsbG8gV29ybGQ=\","
        "\"ephemeral\": false"
        "}";
    call_kv(logosdelivery_send, ctx, "messageJson", msg);

    // Clean up
    logosdelivery_stop_node(ctx, callback, NULL, empty, empty_len);
    logosdelivery_destroy(ctx);

    return 0;
}
```

A complete, runnable version lives in
`library/examples/logosdelivery_example.c` (`make logosdelivery_example`).

## Architecture

The library is structured as follows:

- `liblogosdelivery.h`: C header file with function declarations
- `liblogosdelivery.nim`: Main library entry point
- `declare_lib.nim`: Library declaration and initialization
- `logos_delivery_api/node_api.nim`: Node lifecycle API implementation
- `logos_delivery_api/messaging_api.nim`: Subscribe/send API implementation
- `events/event_bodies.nim`: CBOR-friendly event payload types

The library uses the nim-ffi framework for FFI infrastructure, which handles:
- Thread-safe request processing
- Async operation management
- Memory management between C and Nim
- Callback marshaling

## See Also

- Main API documentation: `logos_delivery/api/`
- Kernel (advanced) surface: `library/liblogosdelivery_kernel.h`
- nim-ffi framework: <https://github.com/logos-messaging/nim-ffi>
