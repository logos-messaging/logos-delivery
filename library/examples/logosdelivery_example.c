#include "../liblogosdelivery.h"
#include "json_utils.h"
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <stdlib.h>

static int create_node_ok = -1;

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
        extract_json_field(eventJson, "messageHash", messageHash, sizeof(messageHash));

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

                // Decode payload from JSON byte array to string
                char payload[4096];
                int payloadLen = decode_json_byte_array(msgJson, "payload", payload, sizeof(payload));

                printf("[EVENT] Message received - Hash: %s, ContentTopic: %s\n", messageHash, contentTopic);
                if (payloadLen > 0) {
                    printf("        Payload (%d bytes): %.*s\n", payloadLen, payloadLen, payload);
                } else {
                    printf("        Payload: (empty or could not decode)\n");
                }

                free(msgJson);
            }
        } else {
            printf("[EVENT] Message received - Hash: %s (could not parse message)\n", messageHash);
        }
        got_message_received = 1;

    } else {
        printf("[EVENT] Unknown event type: %s\n", eventType);
    }

    free(eventJson);
}

// Constructor callback (LogosDeliveryCreateRawFn): reports the terminal result
// of create_node. `ctxAddr` is the context address as text on success.
void on_created(int ret, const char *ctxAddr, const char *errMsg, void *userData) {
    create_node_ok = (ret == RET_OK) ? 1 : 0;
    if (ret != RET_OK) {
        printf("[create_node] Error: %s\n", errMsg ? errMsg : "unknown error");
    }
}

// Reply callback for the argument-taking calls (subscribe, unsubscribe, send,
// get_node_info). `reply` is the result on success, `errMsg` on failure.
void on_reply(int ret, const char *reply, const char *errMsg, void *userData) {
    const char *operation = (const char *)userData;
    if (ret == RET_OK) {
        printf("[%s] Success: %s\n", operation, reply ? reply : "");
    } else {
        printf("[%s] Error: %s\n", operation, errMsg ? errMsg : "unknown error");
    }
}

// Raw callback for the no-argument calls (start_node, stop_node,
// get_available_*). `msg` is `len` bytes and not NUL-terminated.
void on_scalar(int ret, char *msg, size_t len, void *userData) {
    const char *operation = (const char *)userData;
    if (ret == RET_STALE_WARN) {
        return; // non-terminal progress tick
    }
    if (ret == RET_OK) {
        printf("[%s] Success: %.*s\n", operation, (int)len, msg);
    } else {
        printf("[%s] Error: %.*s\n", operation, (int)len, msg);
    }
}


// --- Per-channel encryption ------------------------------------------------
// Two channels, two different schemes, one left in the clear. Both ciphers
// here are illustrative plumbing, NOT production crypto -- see the Nim
// example for a real AEAD.

// XOR keystream.
static int xor_crypt(const uint8_t *in, size_t in_len,
                     LogosDeliveryCryptoSink sink, void *sink_ctx,
                     void *user_data) {
    const char *key = (const char *)user_data;
    const size_t key_len = strlen(key);
    if (key_len == 0) {
        return -1;
    }

    uint8_t stack_buf[512];
    uint8_t *buf = (in_len <= sizeof(stack_buf)) ? stack_buf : malloc(in_len);
    if (in_len > 0 && buf == NULL) {
        return -2;
    }
    for (size_t i = 0; i < in_len; i++) {
        buf[i] = in[i] ^ (uint8_t)key[i % key_len];
    }

    // The bytes are copied out during this call, so freeing right after is safe.
    sink(buf, in_len, sink_ctx);
    if (buf != stack_buf) {
        free(buf);
    }
    return 0;
}

// Add-then-rotate, so the two channels visibly disagree. Self-inverse it is
// not, hence a separate encrypt and decrypt.
static uint8_t rot_key(void *user_data) { return (uint8_t)(uintptr_t)user_data; }

static int rot_encrypt(const uint8_t *in, size_t in_len,
                       LogosDeliveryCryptoSink sink, void *sink_ctx,
                       void *user_data) {
    const uint8_t k = rot_key(user_data);
    for (size_t i = 0; i < in_len; i++) {
        // Emitted one byte at a time purely to show the sink may be called
        // repeatedly; a real cipher would buffer and call it once.
        uint8_t b = (uint8_t)(in[i] + k + (uint8_t)i);
        sink(&b, 1, sink_ctx);
    }
    if (in_len == 0) {
        sink(NULL, 0, sink_ctx);
    }
    return 0;
}

static int rot_decrypt(const uint8_t *in, size_t in_len,
                       LogosDeliveryCryptoSink sink, void *sink_ctx,
                       void *user_data) {
    const uint8_t k = rot_key(user_data);
    for (size_t i = 0; i < in_len; i++) {
        uint8_t b = (uint8_t)(in[i] - k - (uint8_t)i);
        sink(&b, 1, sink_ctx);
    }
    if (in_len == 0) {
        sink(NULL, 0, sink_ctx);
    }
    return 0;
}

// nim-ffi has no function-pointer parameter kind, so the callbacks travel as
// uint64_t. This wrapper keeps the cast in one place.
static int set_channel_encryption(void *ctx, const char *channel_id,
                                  LogosDeliveryCryptoFn encrypt,
                                  LogosDeliveryCryptoFn decrypt,
                                  void *crypto_user_data) {
    LogosdeliveryChannelSetEncryptionReq req = {
        .channelIdStr = channel_id,
        .encryptFn = (uint64_t)(uintptr_t)encrypt,
        .decryptFn = (uint64_t)(uintptr_t)decrypt,
        .cryptoUserData = (uint64_t)(uintptr_t)crypto_user_data,
    };
    return logosdelivery_channel_set_encryption(ctx, on_reply,
                                                (void *)"set_encryption", &req);
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
    LogosdeliveryCreateNodeCtorReq createReq = { .configJson = config };
    void *ctx = logosdelivery_create_node(&createReq, on_created, NULL);
    if (ctx == NULL) {
        printf("Failed to create node\n");
        return 1;
    }

    // Wait a bit for the callback
    sleep(1);

    if (create_node_ok != 1) {
        printf("Create node failed, stopping example early.\n");
        logosdelivery_destroy(ctx);
        return 1;
    }

    printf("\n2. Setting up event listeners...\n");
    logosdelivery_add_event_listener(ctx, "onMessageSent", event_callback, NULL);
    logosdelivery_add_event_listener(ctx, "onMessagePropagated", event_callback, NULL);
    logosdelivery_add_event_listener(ctx, "onMessageError", event_callback, NULL);
    logosdelivery_add_event_listener(ctx, "onChannelMessageReceived", event_callback, NULL);
    logosdelivery_add_event_listener(ctx, "onChannelMessageSent", event_callback, NULL);
    logosdelivery_add_event_listener(ctx, "onChannelMessageError", event_callback, NULL);
    printf("Event listeners registered for message and channel events\n");

    printf("\n3. Starting node...\n");
    logosdelivery_start_node(ctx, on_scalar, (void *)"start_node");

    // Wait for node to start
    sleep(5);

    printf("\n4. Subscribing to content topic...\n");
    const char *contentTopic = "/example/1/chat/proto";
    LogosdeliverySubscribeReq subscribeReq = { .contentTopicStr = contentTopic };
    logosdelivery_subscribe(ctx, on_reply, (void *)"subscribe", &subscribeReq);

    // Wait for subscription
    sleep(1);

    printf("\n5. Retrieving all possible node info ids...\n");
    logosdelivery_get_available_node_info_ids(ctx, on_scalar, (void *)"get_available_node_info_ids");

    printf("\nRetrieving node info for a specific invalid ID...\n");
    LogosdeliveryGetNodeInfoReq nodeInfoReq = { .nodeInfoId = "WrongNodeInfoId" };
    logosdelivery_get_node_info(ctx, on_reply, (void *)"get_node_info", &nodeInfoReq);

    printf("\nRetrieving several node info for specific correct IDs...\n");
    const char *nodeInfoIds[] = {"Version", "MyMultiaddresses", "MyENR", "MyPeerId"};
    for (size_t i = 0; i < sizeof(nodeInfoIds) / sizeof(nodeInfoIds[0]); i++) {
        LogosdeliveryGetNodeInfoReq req = { .nodeInfoId = nodeInfoIds[i] };
        logosdelivery_get_node_info(ctx, on_reply, (void *)"get_node_info", &req);
    }

    printf("\nRetrieving available configs...\n");
    logosdelivery_get_available_configs(ctx, on_scalar, (void *)"get_available_configs");

    printf("\n6. Sending a message...\n");
    printf("Watch for message events (sent, propagated, or error):\n");
    // Create base64-encoded payload: "Hello, Logos Messaging!"
    const char *message = "{"
        "\"contentTopic\": \"/example/1/chat/proto\","
        "\"payload\": \"SGVsbG8sIExvZ29zIE1lc3NhZ2luZyE=\","
        "\"ephemeral\": false"
    "}";
    LogosdeliverySendReq sendReq = { .messageJson = message };
    logosdelivery_send(ctx, on_reply, (void *)"send", &sendReq);

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
    // Registered before the channels are created, so nothing can ever arrive
    // on them in the clear. Registration survives channel close, so
    // `user_data` must outlive the channel.
    static char xor_key[] = "example-xor-key";
    set_channel_encryption(ctx, "#xor", xor_crypt, xor_crypt, xor_key);
    set_channel_encryption(ctx, "#rot", rot_encrypt, rot_decrypt,
                           (void *)(uintptr_t)0x2Bu);
    sleep(1);

    const char *channels[][2] = {
        {"#xor", "/example/1/xor/proto"},
        {"#rot", "/example/1/rot/proto"},
        {"#plain", "/example/1/plain/proto"},  // no cipher registered
    };
    for (size_t i = 0; i < sizeof(channels) / sizeof(channels[0]); i++) {
        LogosdeliveryChannelCreateReq createChanReq = {
            .channelIdStr = channels[i][0],
            .contentTopicStr = channels[i][1],
            .senderIdStr = "logosdelivery-example",
        };
        logosdelivery_channel_create(ctx, on_reply, (void *)"channel_create",
                                     &createChanReq);
    }
    sleep(1);

    for (size_t i = 0; i < sizeof(channels) / sizeof(channels[0]); i++) {
        LogosdeliveryChannelSendReq chanSendReq = {
            .channelIdStr = channels[i][0],
            .messageJson = "{\"payload\": \"SGVsbG8sIExvZ29zIE1lc3NhZ2luZyE=\","
                           "\"ephemeral\": false}",
        };
        logosdelivery_channel_send(ctx, on_reply, (void *)"channel_send",
                                   &chanSendReq);
    }
    sleep(2);

    // Stops new messages picking the cipher up; anything in flight keeps
    // using it, so `user_data` must live until logosdelivery_destroy.
    LogosdeliveryChannelClearEncryptionReq clearReq = {.channelIdStr = "#xor"};
    logosdelivery_channel_clear_encryption(ctx, on_reply,
                                           (void *)"clear_encryption", &clearReq);
    sleep(1);

    printf("\n8. Unsubscribing from content topic...\n");
    LogosdeliveryUnsubscribeReq unsubscribeReq = { .contentTopicStr = contentTopic };
    logosdelivery_unsubscribe(ctx, on_reply, (void *)"unsubscribe", &unsubscribeReq);

    sleep(1);

    printf("\n9. Stopping node...\n");
    logosdelivery_stop_node(ctx, on_scalar, (void *)"stop_node");

    sleep(1);

    printf("\n10. Destroying context...\n");
    logosdelivery_destroy(ctx);

    printf("\n=== Example completed ===\n");
    return 0;
}
