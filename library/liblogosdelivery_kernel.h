
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

  // Creates a new instance of the waku node.
  // Sets up the waku node from the given configuration.
  // Returns a pointer to the Context needed by the rest of the API functions.
  void *waku_new(
      const char *configJson,
      FFICallBack callback,
      void *userData);

  int waku_start(void *ctx,
                 FFICallBack callback,
                 void *userData);

  int waku_stop(void *ctx,
                FFICallBack callback,
                void *userData);

  // Destroys an instance of a waku node created with waku_new
  int waku_destroy(void *ctx,
                   FFICallBack callback,
                   void *userData);

  int waku_version(void *ctx,
                   FFICallBack callback,
                   void *userData);

  // NOTE: event callbacks are registered via logosdelivery_set_event_callback
  // (declared above) which the waku_* API shares.

  int waku_content_topic(void *ctx,
                         FFICallBack callback,
                         void *userData,
                         const char *appName,
                         unsigned int appVersion,
                         const char *contentTopicName,
                         const char *encoding);

  int waku_pubsub_topic(void *ctx,
                        FFICallBack callback,
                        void *userData,
                        const char *topicName);

  int waku_default_pubsub_topic(void *ctx,
                                FFICallBack callback,
                                void *userData);

  int waku_relay_publish(void *ctx,
                         FFICallBack callback,
                         void *userData,
                         const char *pubSubTopic,
                         const char *jsonWakuMessage,
                         unsigned int timeoutMs);

  int waku_lightpush_publish(void *ctx,
                             FFICallBack callback,
                             void *userData,
                             const char *pubSubTopic,
                             const char *jsonWakuMessage);

  int waku_relay_subscribe(void *ctx,
                           FFICallBack callback,
                           void *userData,
                           const char *pubSubTopic);

  int waku_relay_add_protected_shard(void *ctx,
                                     FFICallBack callback,
                                     void *userData,
                                     int clusterId,
                                     int shardId,
                                     char *publicKey);

  int waku_relay_unsubscribe(void *ctx,
                             FFICallBack callback,
                             void *userData,
                             const char *pubSubTopic);

  int waku_filter_subscribe(void *ctx,
                            FFICallBack callback,
                            void *userData,
                            const char *pubSubTopic,
                            const char *contentTopics);

  int waku_filter_unsubscribe(void *ctx,
                              FFICallBack callback,
                              void *userData,
                              const char *pubSubTopic,
                              const char *contentTopics);

  int waku_filter_unsubscribe_all(void *ctx,
                                  FFICallBack callback,
                                  void *userData);

  int waku_relay_get_num_connected_peers(void *ctx,
                                         FFICallBack callback,
                                         void *userData,
                                         const char *pubSubTopic);

  int waku_relay_get_connected_peers(void *ctx,
                                     FFICallBack callback,
                                     void *userData,
                                     const char *pubSubTopic);

  int waku_relay_get_num_peers_in_mesh(void *ctx,
                                       FFICallBack callback,
                                       void *userData,
                                       const char *pubSubTopic);

  int waku_relay_get_peers_in_mesh(void *ctx,
                                   FFICallBack callback,
                                   void *userData,
                                   const char *pubSubTopic);

  int waku_store_query(void *ctx,
                       FFICallBack callback,
                       void *userData,
                       const char *jsonQuery,
                       const char *peerAddr,
                       int timeoutMs);

  int waku_connect(void *ctx,
                   FFICallBack callback,
                   void *userData,
                   const char *peerMultiAddr,
                   unsigned int timeoutMs);

  int waku_disconnect_peer_by_id(void *ctx,
                                 FFICallBack callback,
                                 void *userData,
                                 const char *peerId);

  int waku_disconnect_all_peers(void *ctx,
                                FFICallBack callback,
                                void *userData);

  int waku_dial_peer(void *ctx,
                     FFICallBack callback,
                     void *userData,
                     const char *peerMultiAddr,
                     const char *protocol,
                     int timeoutMs);

  int waku_dial_peer_by_id(void *ctx,
                           FFICallBack callback,
                           void *userData,
                           const char *peerId,
                           const char *protocol,
                           int timeoutMs);

  int waku_get_peerids_from_peerstore(void *ctx,
                                      FFICallBack callback,
                                      void *userData);

  int waku_get_connected_peers_info(void *ctx,
                                    FFICallBack callback,
                                    void *userData);

  int waku_get_peerids_by_protocol(void *ctx,
                                   FFICallBack callback,
                                   void *userData,
                                   const char *protocol);

  int waku_listen_addresses(void *ctx,
                            FFICallBack callback,
                            void *userData);

  int waku_get_connected_peers(void *ctx,
                               FFICallBack callback,
                               void *userData);

  // Returns a list of multiaddress given a url to a DNS discoverable ENR tree
  // Parameters
  //     char* entTreeUrl: URL containing a discoverable ENR tree
  //     char* nameDnsServer: The nameserver to resolve the ENR tree url.
  //     int timeoutMs: Timeout value in milliseconds to execute the call.
  int waku_dns_discovery(void *ctx,
                         FFICallBack callback,
                         void *userData,
                         const char *entTreeUrl,
                         const char *nameDnsServer,
                         int timeoutMs);

  // Updates the bootnode list used for discovering new peers via DiscoveryV5
  // bootnodes - JSON array containing the bootnode ENRs i.e. `["enr:...", "enr:..."]`
  int waku_discv5_update_bootnodes(void *ctx,
                                   FFICallBack callback,
                                   void *userData,
                                   char *bootnodes);

  int waku_start_discv5(void *ctx,
                        FFICallBack callback,
                        void *userData);

  int waku_stop_discv5(void *ctx,
                       FFICallBack callback,
                       void *userData);

  // Retrieves the ENR information
  int waku_get_my_enr(void *ctx,
                      FFICallBack callback,
                      void *userData);

  int waku_get_my_peerid(void *ctx,
                         FFICallBack callback,
                         void *userData);

  int waku_get_metrics(void *ctx,
                       FFICallBack callback,
                       void *userData);

  int waku_peer_exchange_request(void *ctx,
                                 FFICallBack callback,
                                 void *userData,
                                 int numPeers);

  int waku_ping_peer(void *ctx,
                     FFICallBack callback,
                     void *userData,
                     const char *peerAddr,
                     int timeoutMs);

  int waku_is_online(void *ctx,
                     FFICallBack callback,
                     void *userData);

#ifdef __cplusplus
}
#endif

#endif /* __liblogosdelivery_kernel__ */
