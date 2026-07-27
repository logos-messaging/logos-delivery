
// Generated manually and inspired by libwaku.h
// Header file for Logos Messaging API (LMAPI) library
//
// ABI note (nim-ffi >= 0.2): requests and successful responses travel as
// CBOR-encoded byte buffers (RFC 8949), produced by nim-ffi's ffiCtor / ffi
// macros.
//   - Request payloads are CBOR maps whose keys are the Nim-side proc's
//     parameter names (e.g. {"configJson": "<json>"} for create_node). A proc
//     with no parameters takes the placeholder map {"_placeholder": 0}.
//   - Success responses are CBOR-encoded values matching the Nim-side return
//     type — here always a CBOR text string.
//   - Error responses are raw UTF-8 (NOT CBOR), as before.
//   - Library-initiated events are CBOR maps {"eventType": <name>,
//     "payload": <event body>}; see the event section at the bottom.
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
  // reqCbor must point to a CBOR-encoded map {"configJson": "<json>"};
  // reqCborLen is its length in bytes. The synchronous return is the context
  // pointer needed by the rest of the API (or NULL on early failure); the
  // callback fires later with the result of the async initialization (a CBOR
  // text string holding the context address on success, raw UTF-8 on error).
  //
  // The configuration is a JSON object with these optional keys:
  //   "mode": "Core" | "Edge"        (messaging role; defaults to "Core")
  //   "preset": "<network preset>"   (e.g. "twn")
  //   "messagingOverrides": { ... }  (per-field messaging config overrides)
  //   "channelsOverrides": { ... }   (per-field reliable-channel overrides)
  // Override keys accept the config field name or its CLI switch name (e.g.
  // "clusterId" or "cluster-id"). Unknown keys are rejected.
  // Example: {"mode":"Core","messagingOverrides":{"cluster-id":42,"log-level":"INFO"}}
  void *logosdelivery_create_node(
      const uint8_t *reqCbor,
      size_t reqCborLen,
      FFICallBack callback,
      void *userData);

  // Destroys a context created with logosdelivery_create_node and returns its
  // slot to the context pool. Synchronous: returns RET_OK on success, RET_ERR
  // on a null/invalid context. No callback, no userData — the destructor
  // cannot fail asynchronously. Stop the node first with
  // logosdelivery_stop_node.
  int logosdelivery_destroy(void *ctx);

  // Every remaining proc shares the same shape:
  //   int proc(ctx, callback, userData, reqCbor, reqCborLen)
  // reqCbor / reqCborLen carry the per-proc CBOR-encoded request map; the
  // callback later fires with the CBOR-encoded response (or raw UTF-8 error).
  // The synchronous int return is RET_OK / RET_ERR / RET_MISSING_CALLBACK and
  // only reports whether the request was accepted, not its outcome.

  // {} (encoded as the placeholder map {"_placeholder": 0})
  int logosdelivery_start_node(void *ctx,
                               FFICallBack callback,
                               void *userData,
                               const uint8_t *reqCbor,
                               size_t reqCborLen);

  // {} (placeholder map)
  int logosdelivery_stop_node(void *ctx,
                              FFICallBack callback,
                              void *userData,
                              const uint8_t *reqCbor,
                              size_t reqCborLen);

  // Subscribe to a content topic.
  // {"contentTopic": "/myapp/1/chat/proto"}
  int logosdelivery_subscribe(void *ctx,
                              FFICallBack callback,
                              void *userData,
                              const uint8_t *reqCbor,
                              size_t reqCborLen);

  // Unsubscribe from a content topic.
  // {"contentTopic": "/myapp/1/chat/proto"}
  int logosdelivery_unsubscribe(void *ctx,
                                FFICallBack callback,
                                void *userData,
                                const uint8_t *reqCbor,
                                size_t reqCborLen);

  // Send a message. {"messageJson": "<json>"} where the JSON is:
  // {
  //   "contentTopic": "/myapp/1/chat/proto",
  //   "payload": "base64-encoded-payload",
  //   "ephemeral": false
  // }
  // The callback delivers a CBOR text string holding the request ID, which can
  // be used to track the message delivery through the events below.
  int logosdelivery_send(void *ctx,
                         FFICallBack callback,
                         void *userData,
                         const uint8_t *reqCbor,
                         size_t reqCborLen);

  // --- Reliable Channels API (stable surface) ---

  // Create a reliable channel; the callback delivers the channel id.
  // {"channelId": "<id>", "contentTopic": "<topic>", "senderId": "<id>"}
  int logosdelivery_channel_create(void *ctx,
                                   FFICallBack callback,
                                   void *userData,
                                   const uint8_t *reqCbor,
                                   size_t reqCborLen);

  // Check whether a reliable channel is currently open. The callback delivers
  // "true" or "false"; an unknown channel id is not an error.
  // {"channelId": "<id>"}
  int logosdelivery_channel_exists(void *ctx,
                                   FFICallBack callback,
                                   void *userData,
                                   const uint8_t *reqCbor,
                                   size_t reqCborLen);

  // Send a message on a reliable channel; the callback delivers a request ID.
  // {"channelId": "<id>", "messageJson": "<json>"} where the JSON is
  // { "payload": "base64-encoded-payload", "ephemeral": false }
  int logosdelivery_channel_send(void *ctx,
                                 FFICallBack callback,
                                 void *userData,
                                 const uint8_t *reqCbor,
                                 size_t reqCborLen);

  // Close a reliable channel: stops its SDS loops; persisted state survives, so
  // re-creating the channel restores it.
  // {"channelId": "<id>"}
  int logosdelivery_channel_close(void *ctx,
                                  FFICallBack callback,
                                  void *userData,
                                  const uint8_t *reqCbor,
                                  size_t reqCborLen);

  // Retrieves the list of available node info IDs. {} (placeholder map)
  int logosdelivery_get_available_node_info_ids(void *ctx,
                                                FFICallBack callback,
                                                void *userData,
                                                const uint8_t *reqCbor,
                                                size_t reqCborLen);

  // Given a node info ID, retrieves the corresponding info.
  // {"nodeInfoId": "<id>"}
  int logosdelivery_get_node_info(void *ctx,
                                  FFICallBack callback,
                                  void *userData,
                                  const uint8_t *reqCbor,
                                  size_t reqCborLen);

  // Retrieves the list of available configurations. {} (placeholder map)
  int logosdelivery_get_available_configs(void *ctx,
                                          FFICallBack callback,
                                          void *userData,
                                          const uint8_t *reqCbor,
                                          size_t reqCborLen);

  // --- Events ---
  //
  // Events are delivered per event name: register one listener per event you
  // care about (the single wildcard callback of earlier versions is gone).
  // `callback` receives a CBOR-encoded map
  //   {"eventType": "<name>", "payload": { ...event body... }}
  // and is invoked on the library's event thread, so it must be fast,
  // non-blocking and thread-safe.
  //
  // Returns the listener id (> 0), or 0 if the context or callback is invalid.
  uint64_t logosdelivery_add_event_listener(void *ctx,
                                            const char *eventName,
                                            FFICallBack callback,
                                            void *userData);

  // Unregisters a listener previously returned by
  // logosdelivery_add_event_listener. Returns RET_OK (0) on success, non-zero
  // if no listener with that id exists.
  int logosdelivery_remove_event_listener(void *ctx, uint64_t listenerId);

  // Event names and their payload fields:
  //   "message_sent"              { requestId, messageHash }
  //   "message_error"             { requestId, messageHash, error }
  //   "message_propagated"        { requestId, messageHash }
  //   "message_received"          { messageHash, message: <waku message> }
  //   "connection_status_change"  { connectionStatus }
  //   "relay_topic_health_change" { pubsubTopic, topicHealth }
  //   "connection_change"         { peerId, peerEvent }
  //   "channel_message_received"  { channelId, senderId, payload (byte string) }
  //   "channel_message_sent"      { channelId, requestId }
  //   "channel_message_error"     { channelId, requestId, error }
  //   "message"                   { pubsubTopic, messageHash,
  //                                 message: <waku message> }  (kernel relay /
  //                                 filter push; see liblogosdelivery_kernel.h)
  // A <waku message> is the map { payload (byte string), contentTopic, meta
  // (byte string), version, timestamp, ephemeral, proof (byte string) }.

  // NOTE: the low-level kernel API (waku_*) lives in the separate, advanced
  // header liblogosdelivery_kernel.h. It is intentionally not declared here so
  // this header only promises the stable Messaging / Reliable Channels surface.

#ifdef __cplusplus
}
#endif

#endif /* __liblogosdelivery__ */
