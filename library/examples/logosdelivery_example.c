#include "../liblogosdelivery.h"
#include "cbor_helpers.h"
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdint.h>

// Flags set by event callback, polled by main thread
static volatile int got_message_sent = 0;
static volatile int got_message_error = 0;
static volatile int got_message_received = 0;

// ── CBOR event-decode helpers ───────────────────────────────────────────────
//
// Each event arrives as the CBOR encoding of EventEnvelope[T], i.e. a map
// { "eventType": tstr, "payload": <T> }. Inner payloads are themselves
// CBOR maps with one tstr/bstr/uint/bool field per Nim field.

// Print a fixed-width header + a borrowed tstr (no NUL, copy to local buf).
static void print_tstr(const char *label, const char *ptr, size_t len) {
    printf("%s: %.*s", label, (int)len, ptr);
}

// Find a tstr-valued field by name in the map at *off (which is *not*
// consumed; the call clones the offset). Writes the borrowed view through
// *out_ptr / *out_len. Returns 0 on success.
static int find_tstr(const uint8_t *buf, size_t len, size_t payload_off,
                     const char *key, const char **out_ptr, size_t *out_len) {
    size_t cur = payload_off;
    size_t v_off = 0;
    if (cbor_find_in_map(buf, len, &cur, key, &v_off) != 0) return -1;
    return cbor_borrow_tstr(buf, len, &v_off, out_ptr, out_len);
}

static int find_bstr(const uint8_t *buf, size_t len, size_t payload_off,
                     const char *key,
                     const uint8_t **out_ptr, size_t *out_len) {
    size_t cur = payload_off;
    size_t v_off = 0;
    if (cbor_find_in_map(buf, len, &cur, key, &v_off) != 0) return -1;
    return cbor_borrow_bstr(buf, len, &v_off, out_ptr, out_len);
}

// Locate the start of a nested map value (without consuming it) — used to
// recurse into MessageReceived.message. Returns 0 on success.
static int find_submap(const uint8_t *buf, size_t len, size_t payload_off,
                       const char *key, size_t *out_submap_off) {
    size_t cur = payload_off;
    return cbor_find_in_map(buf, len, &cur, key, out_submap_off);
}

void event_callback(int ret, const char *msg, size_t len, void *userData) {
    (void)userData;
    if (ret != RET_OK || msg == NULL || len == 0) return;

    const uint8_t *buf = (const uint8_t *)msg;
    size_t off = 0;

    // Envelope: locate "eventType" and "payload" values. After this call,
    // `off` is at the end of the outer map — we don't reuse it.
    size_t event_type_off = 0;
    size_t payload_off    = 0;
    {
        size_t scan = 0;
        if (cbor_find_in_map(buf, len, &scan, "eventType", &event_type_off) != 0) return;
    }
    {
        size_t scan = 0;
        if (cbor_find_in_map(buf, len, &scan, "payload", &payload_off) != 0) return;
    }

    const char *evt_ptr = NULL;
    size_t evt_len = 0;
    if (cbor_borrow_tstr(buf, len, &event_type_off, &evt_ptr, &evt_len) != 0) return;

    // Most events share the {requestId, messageHash} shape — collect once,
    // then specialise where needed.
    const char *req_ptr = NULL, *hash_ptr = NULL;
    size_t req_len = 0, hash_len = 0;

    if (evt_len == strlen("message_sent") && memcmp(evt_ptr, "message_sent", evt_len) == 0) {
        if (find_tstr(buf, len, payload_off, "requestId",   &req_ptr,  &req_len)  != 0) return;
        if (find_tstr(buf, len, payload_off, "messageHash", &hash_ptr, &hash_len) != 0) return;
        printf("[EVENT] Message sent - RequestID: %.*s, Hash: %.*s\n",
               (int)req_len, req_ptr, (int)hash_len, hash_ptr);
        got_message_sent = 1;

    } else if (evt_len == strlen("message_error") && memcmp(evt_ptr, "message_error", evt_len) == 0) {
        const char *err_ptr = NULL;
        size_t err_len = 0;
        if (find_tstr(buf, len, payload_off, "requestId",   &req_ptr,  &req_len)  != 0) return;
        if (find_tstr(buf, len, payload_off, "messageHash", &hash_ptr, &hash_len) != 0) return;
        if (find_tstr(buf, len, payload_off, "error",       &err_ptr,  &err_len)  != 0) return;
        printf("[EVENT] Message error - RequestID: %.*s, Hash: %.*s, Error: %.*s\n",
               (int)req_len, req_ptr, (int)hash_len, hash_ptr, (int)err_len, err_ptr);
        got_message_error = 1;

    } else if (evt_len == strlen("message_propagated") && memcmp(evt_ptr, "message_propagated", evt_len) == 0) {
        if (find_tstr(buf, len, payload_off, "requestId",   &req_ptr,  &req_len)  != 0) return;
        if (find_tstr(buf, len, payload_off, "messageHash", &hash_ptr, &hash_len) != 0) return;
        printf("[EVENT] Message propagated - RequestID: %.*s, Hash: %.*s\n",
               (int)req_len, req_ptr, (int)hash_len, hash_ptr);

    } else if (evt_len == strlen("connection_status_change") && memcmp(evt_ptr, "connection_status_change", evt_len) == 0) {
        const char *status_ptr = NULL;
        size_t status_len = 0;
        if (find_tstr(buf, len, payload_off, "connectionStatus", &status_ptr, &status_len) != 0) return;
        printf("[EVENT] Connection status change - Status: %.*s\n",
               (int)status_len, status_ptr);

    } else if (evt_len == strlen("message_received") && memcmp(evt_ptr, "message_received", evt_len) == 0) {
        if (find_tstr(buf, len, payload_off, "messageHash", &hash_ptr, &hash_len) != 0) return;
        size_t msg_off = 0;
        if (find_submap(buf, len, payload_off, "message", &msg_off) != 0) return;

        const char *topic_ptr = NULL;
        size_t topic_len = 0;
        const uint8_t *pl_ptr = NULL;
        size_t pl_len = 0;
        if (find_tstr(buf, len, msg_off, "contentTopic", &topic_ptr, &topic_len) != 0) return;
        if (find_bstr(buf, len, msg_off, "payload",      &pl_ptr,    &pl_len)    != 0) return;

        printf("[EVENT] Message received - Hash: %.*s, ContentTopic: %.*s\n",
               (int)hash_len, hash_ptr, (int)topic_len, topic_ptr);
        if (pl_len > 0) {
            printf("        Payload (%zu bytes): %.*s\n", pl_len, (int)pl_len, (const char *)pl_ptr);
        } else {
            printf("        Payload: (empty)\n");
        }
        got_message_received = 1;

    } else {
        printf("[EVENT] Unknown event type: %.*s\n", (int)evt_len, evt_ptr);
    }
}

static volatile int create_node_ok = -1;

// Ctor's callback payload: CBOR text string with the context address on
// success, raw UTF-8 on error. The address is also returned synchronously,
// so we only care about success/failure here.
void create_node_callback(int ret, const char *msg, size_t len, void *userData) {
    (void)userData;
    if (ret != RET_OK) {
        printf("[create_node] Error: %.*s\n", (int)len, msg ? msg : "");
    }
    create_node_ok = ret;
}

// Decodes a CBOR text string response payload into a freshly allocated
// null-terminated string. Returns NULL if the payload isn't a CBOR text
// string (e.g. the placeholder CborNullByte the runtime sends when the
// user-side proc returned "").
static char *decode_response_tstr(const char *msg, size_t len) {
    if (msg == NULL || len == 0) return NULL;
    // Heuristic: cap response strings at 1 MiB for the example.
    const size_t cap = len + 1;
    char *out = malloc(cap);
    if (!out) return NULL;
    size_t out_len = 0;
    if (cbor_decode_tstr((const uint8_t *)msg, len, out, cap, &out_len) != 0) {
        free(out);
        return NULL;
    }
    return out;
}

// Generic completion callback. Success body is CBOR; error body is raw text.
void simple_callback(int ret, const char *msg, size_t len, void *userData) {
    const char *operation = (const char *)userData;
    if (ret == RET_OK) {
        char *decoded = decode_response_tstr(msg, len);
        if (decoded && decoded[0] != '\0') {
            printf("[%s] Success: %s\n", operation, decoded);
        } else {
            printf("[%s] Success\n", operation);
        }
        free(decoded);
    } else {
        printf("[%s] Error: %.*s\n", operation, (int)len, msg ? msg : "");
    }
}

// ── CBOR request helpers (call-site convenience) ────────────────────────────

// Encodes {"<key>": "<val>"} into a fresh malloc'd buffer. Caller frees.
static uint8_t *make_kv_request(const char *key, const char *val, size_t *out_len) {
    const size_t cap = cbor_size_map1_tstr_tstr(key, val);
    uint8_t *buf = malloc(cap);
    if (!buf) return NULL;
    if (cbor_encode_map1_tstr_tstr(buf, cap, key, val, out_len) != 0) {
        free(buf);
        return NULL;
    }
    return buf;
}

// Encodes the placeholder map used by empty-param procs.
static uint8_t *make_empty_request(size_t *out_len) {
    const size_t cap = cbor_size_map1_placeholder();
    uint8_t *buf = malloc(cap);
    if (!buf) return NULL;
    if (cbor_encode_map1_placeholder(buf, cap, out_len) != 0) {
        free(buf);
        return NULL;
    }
    return buf;
}

// ── FFI call wrappers (build CBOR, call, free) ──────────────────────────────

static void call_empty(int (*fn)(void *, FFICallBack, void *, const uint8_t *, size_t),
                       void *ctx, const char *op) {
    size_t req_len = 0;
    uint8_t *req = make_empty_request(&req_len);
    if (!req) { printf("[%s] Error: CBOR encode failed\n", op); return; }
    fn(ctx, simple_callback, (void *)op, req, req_len);
    free(req);
}

static void call_kv(int (*fn)(void *, FFICallBack, void *, const uint8_t *, size_t),
                    void *ctx, const char *op,
                    const char *key, const char *val) {
    size_t req_len = 0;
    uint8_t *req = make_kv_request(key, val, &req_len);
    if (!req) { printf("[%s] Error: CBOR encode failed\n", op); return; }
    fn(ctx, simple_callback, (void *)op, req, req_len);
    free(req);
}

int main() {
    printf("=== Logos Messaging API (LMAPI) Example ===\n\n");

    // Layered messaging config: {mode, preset, messagingOverrides, channelsOverrides}.
    // Override keys are MessagingClientConf field or CLI switch names.
    const char *config = "{"
        "\"mode\": \"Core\","
        "\"preset\": \"logos.dev\","
        "\"messagingOverrides\": {"
            "\"log-level\": \"INFO\""
        "}"
    "}";

    printf("1. Creating node...\n");
    size_t create_req_len = 0;
    uint8_t *create_req = make_kv_request("configJson", config, &create_req_len);
    if (!create_req) {
        printf("Failed to encode create_node request\n");
        return 1;
    }
    void *ctx = logosdelivery_create_node(create_req, create_req_len,
                                          create_node_callback, NULL);
    free(create_req);

    if (ctx == NULL) {
        printf("Failed to create node context\n");
        return 1;
    }

    while (create_node_ok == -1) { usleep(100000); }
    if (create_node_ok != RET_OK) {
        printf("Node initialization failed\n");
        logosdelivery_destroy(ctx);
        return 1;
    }

    printf("\n2. Registering event listeners...\n");
    // nim-ffi 0.2 dropped the single wildcard callback: subscribe per event
    // name, each listener receiving {"eventType": ..., "payload": ...} as CBOR.
    static const char *const events[] = {
        "message_sent", "message_error", "message_propagated", "message_received",
        "connection_status_change",
    };
    for (size_t i = 0; i < sizeof(events) / sizeof(events[0]); i++) {
        const uint64_t id =
            logosdelivery_add_event_listener(ctx, events[i], event_callback, NULL);
        if (id == 0) {
            printf("Failed to register listener for %s\n", events[i]);
        }
    }
    printf("Event listeners registered for message events\n");

    printf("\n3. Starting node...\n");
    call_empty(logosdelivery_start_node, ctx, "start_node");

    // Wait for node to start
    sleep(5);

    printf("\n4. Subscribing to content topic...\n");
    const char *contentTopic = "/example/1/chat/proto";
    call_kv(logosdelivery_subscribe, ctx, "subscribe", "contentTopic", contentTopic);

    // Wait for subscription
    sleep(1);

    printf("\n5. Retrieving all possible node info ids...\n");
    call_empty(logosdelivery_get_available_node_info_ids, ctx, "get_available_node_info_ids");

    printf("\nRetrieving node info for a specific invalid ID...\n");
    call_kv(logosdelivery_get_node_info, ctx, "get_node_info", "nodeInfoId", "WrongNodeInfoId");

    printf("\nRetrieving several node info for specific correct IDs...\n");
    call_kv(logosdelivery_get_node_info, ctx, "get_node_info", "nodeInfoId", "Version");
    call_kv(logosdelivery_get_node_info, ctx, "get_node_info", "nodeInfoId", "MyMultiaddresses");
    call_kv(logosdelivery_get_node_info, ctx, "get_node_info", "nodeInfoId", "MyENR");
    call_kv(logosdelivery_get_node_info, ctx, "get_node_info", "nodeInfoId", "MyPeerId");

    printf("\nRetrieving available configs...\n");
    call_empty(logosdelivery_get_available_configs, ctx, "get_available_configs");

    printf("\n6. Sending a message...\n");
    printf("Watch for message events (sent, propagated, or error):\n");
    const char *envelope =
        "{\"contentTopic\": \"/example/1/chat/proto\","
        "\"payload\": \"SGVsbG8sIExvZ29zIE1lc3NhZ2luZyE=\","
        "\"ephemeral\": false}";
    call_kv(logosdelivery_send, ctx, "send", "messageJson", envelope);

    // Poll for terminal message events (sent, error, or received) with timeout
    printf("Waiting for message delivery events...\n");
    int timeout_sec = 60;
    int elapsed = 0;
    while (!(got_message_sent || got_message_error || got_message_received)
           && elapsed < timeout_sec) {
        usleep(100000); // 100ms
        elapsed++;
    }
    if (elapsed >= timeout_sec) {
        printf("Timed out waiting for message events after %d seconds\n", timeout_sec);
    }

    printf("\n7. Unsubscribing from content topic...\n");
    call_kv(logosdelivery_unsubscribe, ctx, "unsubscribe", "contentTopic", contentTopic);

    sleep(1);

    printf("\n8. Stopping node...\n");
    call_empty(logosdelivery_stop_node, ctx, "stop_node");

    sleep(1);

    printf("\n9. Destroying context...\n");
    const int destroy_ret = logosdelivery_destroy(ctx);
    if (destroy_ret == RET_OK) {
        printf("[destroy] Success\n");
    } else {
        printf("[destroy] Failed (ret=%d)\n", destroy_ret);
    }

    printf("\n=== Example completed ===\n");
    return 0;
}
