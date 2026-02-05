# Logos Messaging API (LMAPI) Library

A C FFI library providing a simplified interface to Logos Messaging functionality.

## Overview

This library wraps the high-level API functions from `waku/api/api.nim` and exposes them via a C FFI interface, making them accessible from C, C++, and other languages that support C FFI.

## API Functions

### Node Lifecycle

#### `lmapi_create_node`
Creates a new instance of the node from the given configuration JSON.

```c
void *lmapi_create_node(
    const char *configJson,
    FFICallBack callback,
    void *userData
);
```

**Parameters:**
- `configJson`: JSON string containing node configuration
- `callback`: Callback function to receive the result
- `userData`: User data passed to the callback

**Returns:** Pointer to the context needed by other API functions, or NULL on error.

**Example configuration JSON:**
```json
{
  "mode": "Core",
  "clusterId": 1,
  "entryNodes": [
    "enrtree://AIRVQ5DDA4FFWLRBCHJWUWOO6X6S4ZTZ5B667LQ6AJU6PEYDLRD5O@sandbox.waku.nodes.status.im"
  ],
  "networkingConfig": {
    "listenIpv4": "0.0.0.0",
    "p2pTcpPort": 60000,
    "discv5UdpPort": 9000
  }
}
```

#### `lmapi_start_node`
Starts the node.

```c
int lmapi_start_node(
    void *ctx,
    FFICallBack callback,
    void *userData
);
```

#### `lmapi_stop_node`
Stops the node.

```c
int lmapi_stop_node(
    void *ctx,
    FFICallBack callback,
    void *userData
);
```

#### `lmapi_destroy`
Destroys a node instance and frees resources.

```c
int lmapi_destroy(
    void *ctx,
    FFICallBack callback,
    void *userData
);
```

### Messaging

#### `lmapi_subscribe`
Subscribe to a content topic to receive messages.

```c
int lmapi_subscribe(
    void *ctx,
    FFICallBack callback,
    void *userData,
    const char *contentTopic
);
```

**Parameters:**
- `ctx`: Context pointer from `lmapi_create_node`
- `callback`: Callback function to receive the result
- `userData`: User data passed to the callback
- `contentTopic`: Content topic string (e.g., "/myapp/1/chat/proto")

#### `lmapi_unsubscribe`
Unsubscribe from a content topic.

```c
int lmapi_unsubscribe(
    void *ctx,
    FFICallBack callback,
    void *userData,
    const char *contentTopic
);
```

#### `lmapi_send`
Send a message.

```c
int lmapi_send(
    void *ctx,
    FFICallBack callback,
    void *userData,
    const char *messageJson
);
```

**Parameters:**
- `messageJson`: JSON string containing the message

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

#### `lmapi_set_event_callback`
Sets a callback that will be invoked whenever an event occurs (e.g., message received).

```c
void lmapi_set_event_callback(
    void *ctx,
    FFICallBack callback,
    void *userData
);
```

**Important:** The callback should be fast, non-blocking, and thread-safe.

## Building

The library follows the same build system as the main Logos Messaging project.

### Build the library

```bash
make liblmapiStatic    # Build static library
# or
make liblmapiDynamic   # Build dynamic library
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
#include "liblmapi.h"
#include <stdio.h>

void callback(int ret, const char *msg, size_t len, void *userData) {
    if (ret == RET_OK) {
        printf("Success: %.*s\n", (int)len, msg);
    } else {
        printf("Error: %.*s\n", (int)len, msg);
    }
}

int main() {
    const char *config = "{"
        "\"mode\": \"Core\","
        "\"clusterId\": 1"
        "}";

    // Create node
    void *ctx = lmapi_create_node(config, callback, NULL);
    if (ctx == NULL) {
        return 1;
    }

    // Start node
    lmapi_start_node(ctx, callback, NULL);

    // Subscribe to a topic
    lmapi_subscribe(ctx, callback, NULL, "/myapp/1/chat/proto");

    // Send a message
    const char *msg = "{"
        "\"contentTopic\": \"/myapp/1/chat/proto\","
        "\"payload\": \"SGVsbG8gV29ybGQ=\","
        "\"ephemeral\": false"
        "}";
    lmapi_send(ctx, callback, NULL, msg);

    // Clean up
    lmapi_stop_node(ctx, callback, NULL);
    lmapi_destroy(ctx, callback, NULL);

    return 0;
}
```

## Architecture

The library is structured as follows:

- `liblmapi.h`: C header file with function declarations
- `liblmapi.nim`: Main library entry point
- `declare_lib.nim`: Library declaration and initialization
- `lmapi/node_api.nim`: Node lifecycle API implementation
- `lmapi/messaging_api.nim`: Subscribe/send API implementation

The library uses the nim-ffi framework for FFI infrastructure, which handles:
- Thread-safe request processing
- Async operation management
- Memory management between C and Nim
- Callback marshaling

## See Also

- Main API documentation: `waku/api/api.nim`
- Original libwaku library: `library/libwaku.nim`
- nim-ffi framework: `vendor/nim-ffi/`
