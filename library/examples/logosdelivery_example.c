#include "../liblogosdelivery.h"
#include "json_utils.h"
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <stdlib.h>

// Set by on_created, polled by the main thread.
static volatile int create_node_done = 0;
static LogosDeliveryCtx *node_ctx = NULL;

// Flags set by event callback, polled by main thread
static volatile int got_message_sent = 0;
static volatile int got_message_error = 0;
static volatile int got_message_received = 0;

// Event callback that handles message events
void event_callback(int ret, const char *msg, size_t len, void *userData) {
    if (ret != RET_OK || msg == NULL || len == 0) {
        return;
    }

    // Create null-terminated string for easier parsing
    char *eventJson = malloc(len + 1);
    if (!eventJson) {
        return;
    }
    memcpy(eventJson, msg, len);
    eventJson[len] = '\0';

    // Extract eventType
    char eventType[64];
    if (!extract_json_field(eventJson, "eventType", eventType, sizeof(eventType))) {
        free(eventJson);
        return;
    }

    // Handle different event types
    if (strcmp(eventType, "message_sent") == 0) {
        char requestId[128];
        char messageHash[128];
        extract_json_field(eventJson, "requestId", requestId, sizeof(requestId));
        extract_json_field(eventJson, "messageHash", messageHash, sizeof(messageHash));
        printf("[EVENT] Message sent - RequestID: %s, Hash: %s\n", requestId, messageHash);
        got_message_sent = 1;

    } else if (strcmp(eventType, "message_error") == 0) {
        char requestId[128];
        char messageHash[128];
        char error[256];
        extract_json_field(eventJson, "requestId", requestId, sizeof(requestId));
        extract_json_field(eventJson, "messageHash", messageHash, sizeof(messageHash));
        extract_json_field(eventJson, "error", error, sizeof(error));
        printf("[EVENT] Message error - RequestID: %s, Hash: %s, Error: %s\n",
               requestId, messageHash, error);
        got_message_error = 1;

    } else if (strcmp(eventType, "message_propagated") == 0) {
        char requestId[128];
        char messageHash[128];
        extract_json_field(eventJson, "requestId", requestId, sizeof(requestId));
        extract_json_field(eventJson, "messageHash", messageHash, sizeof(messageHash));
        printf("[EVENT] Message propagated - RequestID: %s, Hash: %s\n", requestId, messageHash);

    } else if (strcmp(eventType, "connection_status_change") == 0) {
        char connectionStatus[256];
        extract_json_field(eventJson, "connectionStatus", connectionStatus, sizeof(connectionStatus));
        printf("[EVENT] Connection status change - Status: %s\n", connectionStatus);

    } else if (strcmp(eventType, "message_received") == 0) {
        char messageHash[128];
        char source[32]; // "live" from the network, "history" from Store
        extract_json_field(eventJson, "messageHash", messageHash, sizeof(messageHash));
        extract_json_field(eventJson, "source", source, sizeof(source));

        // Extract the nested "message" object
        size_t msgObjLen = 0;
        const char *msgObj = extract_json_object(eventJson, "message", &msgObjLen);
        if (msgObj) {
            // Make a null-terminated copy of the message object
            char *msgJson = malloc(msgObjLen + 1);
            if (msgJson) {
                memcpy(msgJson, msgObj, msgObjLen);
                msgJson[msgObjLen] = '\0';

                char contentTopic[256];
                extract_json_field(msgJson, "contentTopic", contentTopic, sizeof(contentTopic));

                // The payload arrives base64-encoded; decode it for display
                char payload[4096];
                int payloadLen = decode_json_base64_field(msgJson, "payload", payload, sizeof(payload));

                printf("[EVENT] Message received - Hash: %s, ContentTopic: %s, Source: %s\n",
                       messageHash, contentTopic, source);
                if (payloadLen > 0) {
                    printf("        Payload (%d bytes): %.*s\n", payloadLen, payloadLen, payload);
                } else {
                    printf("        Payload: (empty or could not decode)\n");
                }

                free(msgJson);
            }
        } else {
            printf("[EVENT] Message received - Hash: %s, Source: %s (could not parse message)\n",
                   messageHash, source);
        }
        got_message_received = 1;

    } else {
        printf("[EVENT] Unknown event type: %s\n", eventType);
    }

    free(eventJson);
}

// Constructor callback (LogosDeliveryCreateFn). On success `ctx` is a handle
// the caller owns and releases with logosdelivery_ctx_destroy.
void on_created(int ret, LogosDeliveryCtx *ctx, const char *errMsg, void *userData) {
    if (ret == RET_OK) {
        node_ctx = ctx;
    } else {
        printf("[create_node] Error: %s\n", errMsg ? errMsg : "unknown error");
    }
    create_node_done = 1;
}

// Reply callback shared by every logosdelivery_ctx_* call. `reply` is valid
// only during the call.
void on_reply(int ret, const char *const *reply, const char *errMsg, void *userData) {
    const char *operation = (const char *)userData;
    if (ret == RET_OK) {
        printf("[%s] Success: %s\n", operation, reply && *reply ? *reply : "");
    } else {
        printf("[%s] Error: %s\n", operation, errMsg ? errMsg : "unknown error");
    }
}


// --- Per-channel encryption ------------------------------------------------
// Two channels, two different schemes, one left in the clear. Both ciphers
// here are illustrative plumbing, NOT production crypto -- see the Nim
// example for a real AEAD.
//
// The result buffer must outlive the callback's return, so each cipher keeps
// a scratch buffer rather than writing into a stack local. One buffer is
// enough here: the node calls these one at a time on its event loop.

#define CRYPTO_SCRATCH_MAX 262144
static uint8_t crypto_scratch[CRYPTO_SCRATCH_MAX];

// XOR keystream. `user_data` is the key, so one function serves any channel.
static int xor_crypt(void *user_data, const uint8_t *in, size_t in_len,
                     const uint8_t **out, size_t *out_len) {
    const char *key = (const char *)user_data;
    const size_t key_len = strlen(key);
    if (key_len == 0 || in_len > CRYPTO_SCRATCH_MAX) {
        return -1;
    }
    for (size_t i = 0; i < in_len; i++) {
        crypto_scratch[i] = in[i] ^ (uint8_t)key[i % key_len];
    }
    *out = crypto_scratch;
    *out_len = in_len;
    return 0;
}

// Add-then-rotate, so the two channels visibly disagree. Not self-inverse,
// hence a separate encrypt and decrypt. Here `user_data` carries the key by
// value rather than by pointer.
static uint8_t rot_key(void *user_data) { return (uint8_t)(uintptr_t)user_data; }

static int rot_encrypt(void *user_data, const uint8_t *in, size_t in_len,
                       const uint8_t **out, size_t *out_len) {
    const uint8_t k = rot_key(user_data);
    if (in_len > CRYPTO_SCRATCH_MAX) {
        return -1;
    }
    for (size_t i = 0; i < in_len; i++) {
        crypto_scratch[i] = (uint8_t)(in[i] + k + (uint8_t)i);
    }
    *out = crypto_scratch;
    *out_len = in_len;
    return 0;
}

static int rot_decrypt(void *user_data, const uint8_t *in, size_t in_len,
                       const uint8_t **out, size_t *out_len) {
    const uint8_t k = rot_key(user_data);
    if (in_len > CRYPTO_SCRATCH_MAX) {
        return -1;
    }
    for (size_t i = 0; i < in_len; i++) {
        crypto_scratch[i] = (uint8_t)(in[i] - k - (uint8_t)i);
    }
    *out = crypto_scratch;
    *out_len = in_len;
    return 0;
}

// The cipher is given to the channel at creation. nim-ffi has no callback
// parameter kind, so the callbacks travel as uint64_t; this wrapper keeps
// the casts in one place. Pass NULLs for an unencrypted channel.
static int create_channel(const LogosDeliveryCtx *ctx, const char *channel_id,
                          const char *content_topic,
                          LogosDeliveryCryptoFn encrypt,
                          LogosDeliveryCryptoFn decrypt,
                          void *crypto_user_data) {
    return logosdelivery_ctx_channel_create(
        ctx, channel_id, content_topic,
        "logosdelivery-example",
        (uint64_t)(uintptr_t)encrypt, (uint64_t)(uintptr_t)decrypt,
        (uint64_t)(uintptr_t)crypto_user_data,
        on_reply, (void *)"channel_create");
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
    logosdelivery_ctx_create(config, on_created, NULL);

    // Creation is asynchronous: the context arrives in on_created.
    for (int i = 0; i < 100 && !create_node_done; i++) {
        usleep(100000); // 100ms
    }
    if (node_ctx == NULL) {
        printf("Create node failed, stopping example early.\n");
        return 1;
    }
    LogosDeliveryCtx *ctx = node_ctx;

    printf("\n2. Setting up event listeners...\n");
    // The listener registry takes the raw context pointer.
    logosdelivery_add_event_listener(ctx->ptr, "onMessageSent", event_callback, NULL);
    logosdelivery_add_event_listener(ctx->ptr, "onMessagePropagated", event_callback, NULL);
    logosdelivery_add_event_listener(ctx->ptr, "onMessageError", event_callback, NULL);
    logosdelivery_add_event_listener(ctx->ptr, "onChannelMessageReceived", event_callback, NULL);
    logosdelivery_add_event_listener(ctx->ptr, "onChannelMessageSent", event_callback, NULL);
    logosdelivery_add_event_listener(ctx->ptr, "onChannelMessageError", event_callback, NULL);
    printf("Event listeners registered for message and channel events\n");

    printf("\n3. Starting node...\n");
    logosdelivery_ctx_start_node(ctx, on_reply, (void *)"start_node");

    // Wait for node to start
    sleep(5);

    printf("\n4. Subscribing to content topic...\n");
    const char *contentTopic = "/example/1/chat/proto";
    logosdelivery_ctx_subscribe(ctx, contentTopic, on_reply, (void *)"subscribe");

    // Wait for subscription
    sleep(1);

    printf("\n5. Retrieving all possible node info ids...\n");
    logosdelivery_ctx_get_available_node_info_ids(ctx, on_reply, (void *)"get_available_node_info_ids");

    printf("\nRetrieving node info for a specific invalid ID...\n");
    logosdelivery_ctx_get_node_info(ctx, "WrongNodeInfoId", on_reply, (void *)"get_node_info");

    printf("\nRetrieving several node info for specific correct IDs...\n");
    const char *nodeInfoIds[] = {"Version", "MyMultiaddresses", "MyENR", "MyPeerId"};
    for (size_t i = 0; i < sizeof(nodeInfoIds) / sizeof(nodeInfoIds[0]); i++) {
        logosdelivery_ctx_get_node_info(ctx, nodeInfoIds[i], on_reply, (void *)"get_node_info");
    }

    printf("\nRetrieving available configs...\n");
    logosdelivery_ctx_get_available_configs(ctx, on_reply, (void *)"get_available_configs");

    printf("\n6. Sending a message...\n");
    printf("Watch for message events (sent, propagated, or error):\n");
    // Create base64-encoded payload: "Hello, Logos Messaging!"
    const char *message = "{"
        "\"contentTopic\": \"/example/1/chat/proto\","
        "\"payload\": \"SGVsbG8sIExvZ29zIE1lc3NhZ2luZyE=\","
        "\"ephemeral\": false"
    "}";
    logosdelivery_ctx_send(ctx, message, on_reply, (void *)"send");

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

    printf("\n7. Per-channel encryption...\n");
    // Three channels, three schemes. The crypto `user_data` must outlive
    // the channel, so it is static here.
    static char xor_key[] = "example-xor-key";
    create_channel(ctx, "#xor", "/example/1/xor/proto",
                   xor_crypt, xor_crypt, xor_key);
    create_channel(ctx, "#rot", "/example/1/rot/proto",
                   rot_encrypt, rot_decrypt, (void *)(uintptr_t)0x2Bu);
    create_channel(ctx, "#plain", "/example/1/plain/proto",
                   NULL, NULL, NULL);  // unencrypted
    sleep(1);

    const char *channels[] = {"#xor", "#rot", "#plain"};

    for (size_t i = 0; i < sizeof(channels) / sizeof(channels[0]); i++) {
        logosdelivery_ctx_channel_send(
            ctx, channels[i],
            "{\"payload\": \"SGVsbG8sIExvZ29zIE1lc3NhZ2luZyE=\","
            "\"ephemeral\": false}",
            on_reply, (void *)"channel_send");
    }
    sleep(2);

    printf("\n8. Unsubscribing from content topic...\n");
    logosdelivery_ctx_unsubscribe(ctx, contentTopic, on_reply, (void *)"unsubscribe");

    sleep(1);

    printf("\n9. Stopping node...\n");
    logosdelivery_ctx_stop_node(ctx, on_reply, (void *)"stop_node");

    sleep(1);

    printf("\n10. Destroying context...\n");
    logosdelivery_ctx_destroy(ctx);

    printf("\n=== Example completed ===\n");
    return 0;
}
