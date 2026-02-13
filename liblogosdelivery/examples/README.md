# Examples for liblmapi

This directory contains example programs demonstrating the usage of the Logos Messaging API (LMAPI) library.

## Building the Examples

### Prerequisites

1. Build the liblmapi library first:
   ```bash
   cd /path/to/logos-messaging-nim
   make liblmapi
   ```

2. The library will be available in `build/liblmapi.so` (or `.dylib` on macOS, `.dll` on Windows)

### Compile the liblmapi Example

#### On Linux/macOS:
```bash
# Shared library
gcc -o liblogosdelivery_example liblogosdelivery_example.c -I.. -L../../build -llmapi -Wl,-rpath,../../build

# Static library (if built with STATIC=1)
gcc -o liblogosdelivery_example liblogosdelivery_example.c -I.. ../../build/liblmapi.a -lpthread -lm -ldl
```

#### On macOS:
```bash
gcc -o liblogosdelivery_example liblogosdelivery_example.c -I.. -L../../build -llmapi
```

#### On Windows (MinGW):
```bash
gcc -o liblogosdelivery_example.exe liblogosdelivery_example.c -I.. -L../../build -llmapi -lws2_32
```

## Running the Examples

### liblmapi Example

```bash
./liblogosdelivery_example
```

This example demonstrates:
1. Creating a node with configuration
2. Starting the node
3. Subscribing to a content topic
4. Sending a message
5. Unsubscribing from the topic
6. Stopping and destroying the node

### Expected Output

```
=== Logos Messaging API (LMAPI) Example ===

1. Creating node...
[create_node] Success

2. Starting node...
[start_node] Success

3. Subscribing to content topic...
[subscribe] Success

4. Sending a message...
[send] Success: <request-id>

5. Unsubscribing from content topic...
[unsubscribe] Success

6. Stopping node...
[stop_node] Success

7. Destroying context...
[destroy] Success

=== Example completed ===
```

## Notes

- The examples use simple synchronous callbacks with sleep() for demonstration
- In production code, you should use proper async patterns
- Error handling in these examples is basic - production code should be more robust
- The payload in messages must be base64-encoded
