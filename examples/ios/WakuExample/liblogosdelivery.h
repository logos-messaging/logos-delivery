
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

  ////////////////////////////////////////////////////////////////////////////
  // Former libwaku API (waku_*), merged into liblogosdelivery.
  ////////////////////////////////////////////////////////////////////////////

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

#endif /* __liblogosdelivery__ */
