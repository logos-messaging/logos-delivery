
// Generated manually and inspired by libwaku.h
// Header file for Logos Messaging API (LMAPI) library
#pragma once
#ifndef __liblogosdelivery__
#define __liblogosdelivery__

#include <stddef.h>
#include <stdint.h>

// The possible returned values for the functions that return int
#define RET_OK 0
#define RET_ERR 1
#define RET_MISSING_CALLBACK 2

#ifdef __cplusplus
extern "C"
{
#endif

  typedef void (*FFICallBack)(int callerRet, const char *msg, size_t len, void *userData);

  // Creates a new instance of the node from the given configuration JSON.
  // Returns a pointer to the Context needed by the rest of the API functions.
  // Configuration should be in JSON format using WakuNodeConf field names.
  // Field names match Nim identifiers from WakuNodeConf (camelCase).
  // Example: {"mode": "Core", "clusterId": 42, "relay": true}
  void *logosdelivery_create_node(
      const char *configJson,
      FFICallBack callback,
      void *userData);

  // Starts the node.
  int logosdelivery_start_node(void *ctx,
                       FFICallBack callback,
                       void *userData);

  // Stops the node.
  int logosdelivery_stop_node(void *ctx,
                      FFICallBack callback,
                      void *userData);

  // Destroys an instance of a node created with logosdelivery_create_node
  int logosdelivery_destroy(void *ctx,
                    FFICallBack callback,
                    void *userData);

  // Subscribe to a content topic.
  // contentTopic: string representing the content topic (e.g., "/myapp/1/chat/proto")
  int logosdelivery_subscribe(void *ctx,
                      FFICallBack callback,
                      void *userData,
                      const char *contentTopic);

  // Unsubscribe from a content topic.
  int logosdelivery_unsubscribe(void *ctx,
                        FFICallBack callback,
                        void *userData,
                        const char *contentTopic);

  // Send a message.
  // messageJson: JSON string with the following structure:
  // {
  //   "contentTopic": "/myapp/1/chat/proto",
  //   "payload": "base64-encoded-payload",
  //   "ephemeral": false
  // }
  // Returns a request ID that can be used to track the message delivery.
  int logosdelivery_send(void *ctx,
                 FFICallBack callback,
                 void *userData,
                 const char *messageJson);

  // --- Reliable Channels API (stable surface) ---

  // Create a reliable channel. Returns the channel id.
  int logosdelivery_channel_create(void *ctx,
                           FFICallBack callback,
                           void *userData,
                           const char *channelId,
                           const char *contentTopic,
                           const char *senderId);

  // Send a message on a reliable channel.
  // messageJson: { "payload": "base64-encoded-payload", "ephemeral": false }
  // Returns a request ID that can be used to track delivery.
  int logosdelivery_channel_send(void *ctx,
                         FFICallBack callback,
                         void *userData,
                         const char *channelId,
                         const char *messageJson);

  // Close a reliable channel: stops its SDS loops; persisted state survives, so
  // re-creating the channel restores it.
  int logosdelivery_channel_close(void *ctx,
                          FFICallBack callback,
                          void *userData,
                          const char *channelId);

  // Channel lifecycle events are delivered through the event callback set via
  // logosdelivery_set_event_callback: "onChannelMessageReceived" (payload
  // base64-encoded), "onChannelMessageSent", "onChannelMessageError".

  // Sets a callback that will be invoked whenever an event occurs.
  // It is crucial that the passed callback is fast, non-blocking and potentially thread-safe.
  void logosdelivery_set_event_callback(void *ctx,
                                 FFICallBack callback,
                                 void *userData);

  // Retrieves the list of available node info IDs.
  int logosdelivery_get_available_node_info_ids(void *ctx,
                                 FFICallBack callback,
                                 void *userData);

  // Given a node info ID, retrieves the corresponding info.
  int logosdelivery_get_node_info(void *ctx,
                                  FFICallBack callback,
                                  void *userData,
                                  const char *nodeInfoId);

  // Retrieves the list of available configurations.
  int logosdelivery_get_available_configs(void *ctx,
                                    FFICallBack callback,
                                    void *userData);

  // NOTE: the low-level kernel API (waku_*) lives in the separate, advanced
  // header liblogosdelivery_kernel.h. It is intentionally not declared here so
  // this header only promises the stable Messaging / Reliable Channels surface.

#ifdef __cplusplus
}
#endif

#endif /* __liblogosdelivery__ */
