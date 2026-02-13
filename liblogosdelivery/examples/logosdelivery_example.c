#include "../logosdelivery.h"
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <stdlib.h>

// Helper function to extract a JSON string field value
// Very basic parser - for production use a proper JSON library
const char* extract_json_field(const char *json, const char *field, char *buffer, size_t bufSize) {
    char searchStr[256];
    snprintf(searchStr, sizeof(searchStr), "\"%s\":\"", field);

    const char *start = strstr(json, searchStr);
    if (!start) {
        return NULL;
    }

    start += strlen(searchStr);
    const char *end = strchr(start, '"');
    if (!end) {
        return NULL;
    }

    size_t len = end - start;
    if (len >= bufSize) {
        len = bufSize - 1;
    }

    memcpy(buffer, start, len);
    buffer[len] = '\0';

    return buffer;
}

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
        printf("📤 [EVENT] Message sent - RequestID: %s, Hash: %s\n", requestId, messageHash);

    } else if (strcmp(eventType, "message_error") == 0) {
        char requestId[128];
        char messageHash[128];
        char error[256];
        extract_json_field(eventJson, "requestId", requestId, sizeof(requestId));
        extract_json_field(eventJson, "messageHash", messageHash, sizeof(messageHash));
        extract_json_field(eventJson, "error", error, sizeof(error));
        printf("❌ [EVENT] Message error - RequestID: %s, Hash: %s, Error: %s\n",
               requestId, messageHash, error);

    } else if (strcmp(eventType, "message_propagated") == 0) {
        char requestId[128];
        char messageHash[128];
        extract_json_field(eventJson, "requestId", requestId, sizeof(requestId));
        extract_json_field(eventJson, "messageHash", messageHash, sizeof(messageHash));
        printf("✅ [EVENT] Message propagated - RequestID: %s, Hash: %s\n", requestId, messageHash);

    } else {
        printf("ℹ️  [EVENT] Unknown event type: %s\n", eventType);
    }

    free(eventJson);
}

// Simple callback that prints results
void simple_callback(int ret, const char *msg, size_t len, void *userData) {
    const char *operation = (const char *)userData;
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

    // Configuration JSON for creating a node
    const char *config = "{"
        "\"logLevel\": \"TRACE\","
        // "\"mode\": \"Edge\","
        "\"mode\": \"Core\","
        "\"clusterId\": 42,"
        "\"numShards\": 8,"
        // "\"shards\": [0,1,2,3,4,5,6,7],"
        "\"entryNodes\": [\"/dns4/node-01.do-ams3.misc.logos-chat.status.im/tcp/30303/p2p/16Uiu2HAkxoqUTud5LUPQBRmkeL2xP4iKx2kaABYXomQRgmLUgf78\"],"
        "\"networkingConfig\": {"
            "\"listenIpv4\": \"0.0.0.0\","
            "\"p2pTcpPort\": 60000,"
            "\"discv5UdpPort\": 9000"
        "}"
    "}";

    printf("1. Creating node...\n");
    void *ctx = logosdelivery_create_node(config, simple_callback, (void *)"create_node");
    if (ctx == NULL) {
        printf("Failed to create node\n");
        return 1;
    }

    // Wait a bit for the callback
    sleep(1);

    printf("\n2. Setting up event callback...\n");
    logosdelivery_set_event_callback(ctx, event_callback, NULL);
    printf("Event callback registered for message events\n");

    printf("\n3. Starting node...\n");
    logosdelivery_start_node(ctx, simple_callback, (void *)"start_node");

    // Wait for node to start
    sleep(2);

    printf("\n4. Subscribing to content topic...\n");
    const char *contentTopic = "/example/1/chat/proto";
    logosdelivery_subscribe(ctx, simple_callback, (void *)"subscribe", contentTopic);

    // Wait for subscription
    sleep(1);

    printf("\n5. Sending a message...\n");
    printf("Watch for message events (sent, propagated, or error):\n");
    // Create base64-encoded payload: "Hello, Logos Messaging!"
    const char *message = "{"
        "\"contentTopic\": \"/example/1/chat/proto\","
        "\"payload\": \"SGVsbG8sIExvZ29zIE1lc3NhZ2luZyE=\","
        "\"ephemeral\": false"
    "}";
    logosdelivery_send(ctx, simple_callback, (void *)"send", message);

    // Wait for message events to arrive
    printf("Waiting for message delivery events...\n");
    sleep(60);

    printf("\n6. Unsubscribing from content topic...\n");
    logosdelivery_unsubscribe(ctx, simple_callback, (void *)"unsubscribe", contentTopic);

    sleep(1);

    printf("\n7. Stopping node...\n");
    logosdelivery_stop_node(ctx, simple_callback, (void *)"stop_node");

    sleep(1);

    printf("\n8. Destroying context...\n");
    logosdelivery_destroy(ctx, simple_callback, (void *)"destroy");

    printf("\n=== Example completed ===\n");
    return 0;
}
