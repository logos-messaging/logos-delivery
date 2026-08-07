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
    CreateNodeCtorReq createReq = { .configJson = config };
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
    printf("Event listeners registered for message events\n");

    printf("\n3. Starting node...\n");
    logosdelivery_start_node(ctx, on_scalar, (void *)"start_node");

    // Wait for node to start
    sleep(5);

    printf("\n4. Subscribing to content topic...\n");
    const char *contentTopic = "/example/1/chat/proto";
    SubscribeReq subscribeReq = { .contentTopicStr = contentTopic };
    logosdelivery_subscribe(ctx, on_reply, (void *)"subscribe", &subscribeReq);

    // Wait for subscription
    sleep(1);

    printf("\n5. Retrieving all possible node info ids...\n");
    logosdelivery_get_available_node_info_ids(ctx, on_scalar, (void *)"get_available_node_info_ids");

    printf("\nRetrieving node info for a specific invalid ID...\n");
    GetNodeInfoReq nodeInfoReq = { .nodeInfoId = "WrongNodeInfoId" };
    logosdelivery_get_node_info(ctx, on_reply, (void *)"get_node_info", &nodeInfoReq);

    printf("\nRetrieving several node info for specific correct IDs...\n");
    const char *nodeInfoIds[] = {"Version", "MyMultiaddresses", "MyENR", "MyPeerId"};
    for (size_t i = 0; i < sizeof(nodeInfoIds) / sizeof(nodeInfoIds[0]); i++) {
        GetNodeInfoReq req = { .nodeInfoId = nodeInfoIds[i] };
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
    SendReq sendReq = { .messageJson = message };
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

    printf("\n7. Unsubscribing from content topic...\n");
    UnsubscribeReq unsubscribeReq = { .contentTopicStr = contentTopic };
    logosdelivery_unsubscribe(ctx, on_reply, (void *)"unsubscribe", &unsubscribeReq);

    sleep(1);

    printf("\n8. Stopping node...\n");
    logosdelivery_stop_node(ctx, on_scalar, (void *)"stop_node");

    sleep(1);

    printf("\n9. Destroying context...\n");
    logosdelivery_destroy(ctx);

    printf("\n=== Example completed ===\n");
    return 0;
}
