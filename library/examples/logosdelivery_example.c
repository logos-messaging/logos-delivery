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

// Simple callback that prints results
void simple_callback(int ret, const char *msg, size_t len, void *userData) {
    const char *operation = (const char *)userData;

    if (operation != NULL && strcmp(operation, "create_node") == 0) {
        create_node_ok = (ret == RET_OK) ? 1 : 0;
    }

    if (ret == RET_OK) {
        if (len > 0) {
            printf("[%s] Success: %.*s\n", operation, (int)len, msg);
        } else {
            printf("[%s] Success\n", operation);
        }
    } else {
        printf("[%s] Error: %.*s\n", operation, (int)len, msg);
    }
}

int main() {
    printf("=== Logos Messaging API (LMAPI) Example ===\n\n");

    // Configuration JSON using WakuNodeConf field names (flat structure).
    // Field names match Nim identifiers from WakuNodeConf in tools/confutils/cli_args.nim.
    const char *config = "{"
        "\"logLevel\": \"INFO\","
        "\"mode\": \"Core\","
        "\"preset\": \"logos.dev\""
    "}";

    printf("1. Creating node...\n");
    void *ctx = logosdelivery_create_node(config, simple_callback, (void *)"create_node");
    if (ctx == NULL) {
        printf("Failed to create node\n");
        return 1;
    }

    // Wait a bit for the callback
    sleep(1);

    if (create_node_ok != 1) {
        printf("Create node failed, stopping example early.\n");
        logosdelivery_destroy(ctx, simple_callback, (void *)"destroy");
        return 1;
    }

    printf("\n2. Setting up event callback...\n");
    logosdelivery_set_event_callback(ctx, event_callback, NULL);
    printf("Event callback registered for message events\n");

    printf("\n3. Starting node...\n");
    logosdelivery_start_node(ctx, simple_callback, (void *)"start_node");

    // Wait for node to start
    sleep(5);

    printf("\n4. Subscribing to content topic...\n");
    const char *contentTopic = "/example/1/chat/proto";
    logosdelivery_subscribe(ctx, simple_callback, (void *)"subscribe", contentTopic);

    // Wait for subscription
    sleep(1);

    printf("\n5. Retrieving all possibl node info ids...\n");
    logosdelivery_get_available_node_info_ids(ctx, simple_callback, (void *)"get_available_node_info_ids");

    printf("\nRetrieving node info for a specific invalid ID...\n");
    logosdelivery_get_node_info(ctx, simple_callback, (void *)"get_node_info", "WrongNodeInfoId");

    printf("\nRetrieving several node info for specific correct IDs...\n");
    logosdelivery_get_node_info(ctx, simple_callback, (void *)"get_node_info", "Version");
    // logosdelivery_get_node_info(ctx, simple_callback, (void *)"get_node_info", "Metrics");
    logosdelivery_get_node_info(ctx, simple_callback, (void *)"get_node_info", "MyMultiaddresses");
    logosdelivery_get_node_info(ctx, simple_callback, (void *)"get_node_info", "MyENR");
    logosdelivery_get_node_info(ctx, simple_callback, (void *)"get_node_info", "MyPeerId");

    printf("\nRetrieving available configs...\n");
    logosdelivery_get_available_configs(ctx, simple_callback, (void *)"get_available_configs");

    printf("\n6. Sending a message...\n");
    printf("Watch for message events (sent, propagated, or error):\n");
    // Create base64-encoded payload: "Hello, Logos Messaging!"
    const char *message = "{"
        "\"contentTopic\": \"/example/1/chat/proto\","
        "\"payload\": \"SGVsbG8sIExvZ29zIE1lc3NhZ2luZyE=\","
        "\"ephemeral\": false"
    "}";
    logosdelivery_send(ctx, simple_callback, (void *)"send", message);

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
    logosdelivery_unsubscribe(ctx, simple_callback, (void *)"unsubscribe", contentTopic);

    sleep(1);

    printf("\n8. Stopping node...\n");
    logosdelivery_stop_node(ctx, simple_callback, (void *)"stop_node");

    sleep(1);

    printf("\n9. Destroying context...\n");
    logosdelivery_destroy(ctx, simple_callback, (void *)"destroy");

    printf("\n=== Example completed ===\n");
    return 0;
}
