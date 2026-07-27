
// liblogosdelivery_kernel.h — Kernel / advanced API (low-level, per-protocol).
//
// ⚠️  USE AT YOUR OWN RISK — UNSUPPORTED, UNSTABLE SURFACE.
//
// These `waku_*` functions are the low-level kernel API. They are NOT part of
// the stable, supported Messaging / Reliable Channels surface declared in
// liblogosdelivery.h. They expose per-protocol internals (relay, filter,
// lightpush, store, discovery, peer management) and may change or be removed
// at ANY time, without notice or a deprecation cycle.
//
// Including this header is a deliberate opt-in into the advanced tier. If you
// only need messaging, include liblogosdelivery.h and nothing here.
//
// See https://github.com/logos-messaging/logos-delivery/issues/3851 for the
// tiering rationale.
#pragma once
#ifndef __liblogosdelivery_kernel__
#define __liblogosdelivery_kernel__

// Shared FFICallBack typedef and RET_* return codes live in the stable header.
#include "liblogosdelivery.h"

#ifdef __cplusplus
extern "C"
{
#endif

  // NOTE: node lifecycle (create / start / stop / destroy) is unified and lives
  // only in the stable header. Use logosdelivery_create_node,
  // logosdelivery_start_node, logosdelivery_stop_node and logosdelivery_destroy
  // (declared in liblogosdelivery.h, included above) regardless of whether you
  // drive the node through the messaging surface or this kernel API.
  //
  // Every proc below takes the same CBOR request ABI as the stable surface:
  //   int proc(ctx, callback, userData, reqCbor, reqCborLen)
  // where reqCbor is a CBOR map keyed by the Nim-side parameter names (listed
  // above each declaration) and the callback receives a CBOR text string on
  // success or raw UTF-8 on error. Procs with no parameters take the
  // placeholder map {"_placeholder": 0}.
  //
  // NOTE: event callbacks are registered per event name via
  // logosdelivery_add_event_listener (declared in the stable header), which the
  // waku_* API shares. Relay and filter message pushes arrive under the
  // "message" event.

  // --- debug node ---

  // {} (placeholder map)
  int waku_version(void *ctx,
                   FFICallBack callback,
                   void *userData,
                   const uint8_t *reqCbor,
                   size_t reqCborLen);

  // {} (placeholder map)
  int waku_listen_addresses(void *ctx,
                            FFICallBack callback,
                            void *userData,
                            const uint8_t *reqCbor,
                            size_t reqCborLen);

  // {} (placeholder map)
  int waku_get_my_enr(void *ctx,
                      FFICallBack callback,
                      void *userData,
                      const uint8_t *reqCbor,
                      size_t reqCborLen);

  // {} (placeholder map)
  int waku_get_my_peerid(void *ctx,
                         FFICallBack callback,
                         void *userData,
                         const uint8_t *reqCbor,
                         size_t reqCborLen);

  // {} (placeholder map)
  int waku_get_metrics(void *ctx,
                       FFICallBack callback,
                       void *userData,
                       const uint8_t *reqCbor,
                       size_t reqCborLen);

  // {} (placeholder map)
  int waku_is_online(void *ctx,
                     FFICallBack callback,
                     void *userData,
                     const uint8_t *reqCbor,
                     size_t reqCborLen);

  // --- relay ---

  // {"pubSubTopic": ...}
  int waku_relay_get_peers_in_mesh(void *ctx,
                                   FFICallBack callback,
                                   void *userData,
                                   const uint8_t *reqCbor,
                                   size_t reqCborLen);

  // {"pubSubTopic": ...}
  int waku_relay_get_num_peers_in_mesh(void *ctx,
                                       FFICallBack callback,
                                       void *userData,
                                       const uint8_t *reqCbor,
                                       size_t reqCborLen);

  // {"pubSubTopic": ...}
  int waku_relay_get_connected_peers(void *ctx,
                                     FFICallBack callback,
                                     void *userData,
                                     const uint8_t *reqCbor,
                                     size_t reqCborLen);

  // {"pubSubTopic": ...}
  int waku_relay_get_num_connected_peers(void *ctx,
                                         FFICallBack callback,
                                         void *userData,
                                         const uint8_t *reqCbor,
                                         size_t reqCborLen);

  // {"clusterId": ..., "shardId": ..., "publicKey": ...}
  int waku_relay_add_protected_shard(void *ctx,
                                     FFICallBack callback,
                                     void *userData,
                                     const uint8_t *reqCbor,
                                     size_t reqCborLen);

  // {"pubSubTopic": ...}
  int waku_relay_subscribe(void *ctx,
                           FFICallBack callback,
                           void *userData,
                           const uint8_t *reqCbor,
                           size_t reqCborLen);

  // {"pubSubTopic": ...}
  int waku_relay_unsubscribe(void *ctx,
                             FFICallBack callback,
                             void *userData,
                             const uint8_t *reqCbor,
                             size_t reqCborLen);

  // {"pubSubTopic": ..., "jsonWakuMessage": ..., "timeoutMs": ...}
  int waku_relay_publish(void *ctx,
                         FFICallBack callback,
                         void *userData,
                         const uint8_t *reqCbor,
                         size_t reqCborLen);

  // {} (placeholder map)
  int waku_default_pubsub_topic(void *ctx,
                                FFICallBack callback,
                                void *userData,
                                const uint8_t *reqCbor,
                                size_t reqCborLen);

  // {"appName": ..., "appVersion": ..., "contentTopicName": ..., "encoding": ...}
  int waku_content_topic(void *ctx,
                         FFICallBack callback,
                         void *userData,
                         const uint8_t *reqCbor,
                         size_t reqCborLen);

  // {"topicName": ...}
  int waku_pubsub_topic(void *ctx,
                        FFICallBack callback,
                        void *userData,
                        const uint8_t *reqCbor,
                        size_t reqCborLen);

  // --- lightpush ---

  // {"pubSubTopic": ..., "jsonWakuMessage": ...}
  int waku_lightpush_publish(void *ctx,
                             FFICallBack callback,
                             void *userData,
                             const uint8_t *reqCbor,
                             size_t reqCborLen);

  // --- filter ---

  // {"pubSubTopic": ..., "contentTopics": ...}
  int waku_filter_subscribe(void *ctx,
                            FFICallBack callback,
                            void *userData,
                            const uint8_t *reqCbor,
                            size_t reqCborLen);

  // {"pubSubTopic": ..., "contentTopics": ...}
  int waku_filter_unsubscribe(void *ctx,
                              FFICallBack callback,
                              void *userData,
                              const uint8_t *reqCbor,
                              size_t reqCborLen);

  // {} (placeholder map)
  int waku_filter_unsubscribe_all(void *ctx,
                                  FFICallBack callback,
                                  void *userData,
                                  const uint8_t *reqCbor,
                                  size_t reqCborLen);

  // --- store ---

  // {"jsonQuery": ..., "peerAddr": ..., "timeoutMs": ...}
  int waku_store_query(void *ctx,
                       FFICallBack callback,
                       void *userData,
                       const uint8_t *reqCbor,
                       size_t reqCborLen);

  // --- peer manager ---

  // {} (placeholder map)
  int waku_get_peerids_from_peerstore(void *ctx,
                                      FFICallBack callback,
                                      void *userData,
                                      const uint8_t *reqCbor,
                                      size_t reqCborLen);

  // {"peerMultiAddr": ..., "timeoutMs": ...}
  int waku_connect(void *ctx,
                   FFICallBack callback,
                   void *userData,
                   const uint8_t *reqCbor,
                   size_t reqCborLen);

  // {"peerId": ...}
  int waku_disconnect_peer_by_id(void *ctx,
                                 FFICallBack callback,
                                 void *userData,
                                 const uint8_t *reqCbor,
                                 size_t reqCborLen);

  // {} (placeholder map)
  int waku_disconnect_all_peers(void *ctx,
                                FFICallBack callback,
                                void *userData,
                                const uint8_t *reqCbor,
                                size_t reqCborLen);

  // {"peerMultiAddr": ..., "protocol": ..., "timeoutMs": ...}
  int waku_dial_peer(void *ctx,
                     FFICallBack callback,
                     void *userData,
                     const uint8_t *reqCbor,
                     size_t reqCborLen);

  // {"peerId": ..., "protocol": ..., "timeoutMs": ...}
  int waku_dial_peer_by_id(void *ctx,
                           FFICallBack callback,
                           void *userData,
                           const uint8_t *reqCbor,
                           size_t reqCborLen);

  // {} (placeholder map)
  int waku_get_connected_peers_info(void *ctx,
                                    FFICallBack callback,
                                    void *userData,
                                    const uint8_t *reqCbor,
                                    size_t reqCborLen);

  // {} (placeholder map)
  int waku_get_connected_peers(void *ctx,
                               FFICallBack callback,
                               void *userData,
                               const uint8_t *reqCbor,
                               size_t reqCborLen);

  // {"protocol": ...}
  int waku_get_peerids_by_protocol(void *ctx,
                                   FFICallBack callback,
                                   void *userData,
                                   const uint8_t *reqCbor,
                                   size_t reqCborLen);

  // --- discovery ---

  // {"bootnodes": ...}
  int waku_discv5_update_bootnodes(void *ctx,
                                   FFICallBack callback,
                                   void *userData,
                                   const uint8_t *reqCbor,
                                   size_t reqCborLen);

  // {"enrTreeUrl": ..., "nameDnsServer": ..., "timeoutMs": ...}
  int waku_dns_discovery(void *ctx,
                         FFICallBack callback,
                         void *userData,
                         const uint8_t *reqCbor,
                         size_t reqCborLen);

  // {} (placeholder map)
  int waku_start_discv5(void *ctx,
                        FFICallBack callback,
                        void *userData,
                        const uint8_t *reqCbor,
                        size_t reqCborLen);

  // {} (placeholder map)
  int waku_stop_discv5(void *ctx,
                       FFICallBack callback,
                       void *userData,
                       const uint8_t *reqCbor,
                       size_t reqCborLen);

  // {"numPeers": ...}
  int waku_peer_exchange_request(void *ctx,
                                 FFICallBack callback,
                                 void *userData,
                                 const uint8_t *reqCbor,
                                 size_t reqCborLen);

  // --- ping ---

  // {"peerAddr": ..., "timeoutMs": ...}
  int waku_ping_peer(void *ctx,
                     FFICallBack callback,
                     void *userData,
                     const uint8_t *reqCbor,
                     size_t reqCborLen);

#ifdef __cplusplus
}
#endif

#endif /* __liblogosdelivery_kernel__ */
