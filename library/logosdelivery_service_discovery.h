#ifndef __logosdelivery_service_discovery__
#define __logosdelivery_service_discovery__

#include <stddef.h>
#include <stdint.h>

/* Registration rides the generated entry points, so their declarations and the
 * LogosDeliveryCtx helpers must be in scope. */
#include "generated/logosdelivery.h"

/*
 * Service-discovery plugin interface.
 *
 * logos-delivery can delegate peer/service discovery to an external provider
 * (today: logos-libp2p-module, driven by glue in logos-delivery-module). The
 * provider implements the entry points below -- one per libp2p service
 * discovery operation -- and registers them with
 * logosdelivery_set_service_discovery_plugin (see "Registration" below).
 *
 * External service discovery is active only when BOTH hold:
 *   - the node is configured for it, and
 *   - a plugin is registered whose ABI version matches and whose every
 *     entry point is non-NULL.
 * Configuration alone leaves the backend inert: its verbs fail with a clear
 * error until a valid plugin arrives. Registration alone is refused, because
 * without the configuration there is no backend to register with.
 *
 * Scope:
 *   - A registration belongs to one node. A process may hold several nodes;
 *     each keeps its own plugin and its own discovery thread, for as long as
 *     that node exists. Registering for one node never disturbs another, and
 *     tearing one down leaves the others running.
 *
 * Calling model:
 *   - logos-delivery drives the plugin through the lifecycle these entry
 *     points describe: start, then lookups while the node runs, then stop.
 *     What the plugin does internally to serve them is its own business.
 *   - Every entry point is a plain blocking request: it performs the work and
 *     returns its result. There are no completion callbacks and no events
 *     from the plugin back into logos-delivery.
 *   - Entry points are invoked on that node's discovery thread inside
 *     logos-delivery, never on the node's event loop, so they MAY block for
 *     as long as the operation genuinely takes (a cold DHT bootstrap can run
 *     for tens of seconds).
 *   - Calls from one node are serialized: its discovery thread runs one entry
 *     point at a time. A vtable registered for SEVERAL nodes is called from
 *     each of their threads, so it must tolerate concurrent calls.
 *
 * Results:
 *   - Lookups return JSON, matching what the libp2p module already produces:
 *       [ { "peerId": "16Uiu2...",
 *           "seqNo": 1730000000,
 *           "addrs": ["/ip4/1.2.3.4/tcp/60000"],
 *           "services": [ { "id": "/mix/1.0.0", "data": "<base64>" } ] } ]
 *     `services` is an array (ids may repeat) and each `data` is base64.
 *     An empty array means "no peers", not an error.
 *   - The JSON string is owned by the plugin; logos-delivery parses it and
 *     then hands it back to freeString.
 *
 * Memory:
 *   - Arguments are borrowed for the duration of the call; the plugin copies
 *     what it needs to keep.
 *   - Error text is written into the caller-provided errBuf (NUL-terminated,
 *     truncated to errBufLen); no allocation crosses the boundary for errors.
 *   - Strings are NUL-terminated UTF-8. Byte runs use an explicit length and
 *     may be NULL when the length is 0.
 */

#ifdef __cplusplus
extern "C"
{
#endif

#define LD_DISCO_ABI_VERSION 1

  /* Entry point return codes. */
#define LD_DISCO_OK 0
#define LD_DISCO_ERROR 1

  /* ----------------------------------------------- plugin entry points -- */
  /* All implemented by the plugin. Return LD_DISCO_OK or LD_DISCO_ERROR;
   * on error, write a message into errBuf. */

  typedef int (*LdDiscoStartFn)(void *pluginCtx, char *errBuf, size_t errBufLen);

  typedef int (*LdDiscoStopFn)(void *pluginCtx, char *errBuf, size_t errBufLen);

  /* `key` is a criteria key ("svc:<id>", "shard:<cluster>/<shard>",
   * "cap:<capability>"); `limit` <= 0 means the plugin's own default.
   * On success *outJson receives a plugin-owned JSON array (see above). */
  typedef int (*LdDiscoLookupFn)(void *pluginCtx,
                                 const char *key,
                                 int64_t limit,
                                 char **outJson,
                                 char *errBuf,
                                 size_t errBufLen);

  typedef int (*LdDiscoRandomLookupFn)(void *pluginCtx,
                                       char **outJson,
                                       char *errBuf,
                                       size_t errBufLen);

  /* Releases a string previously produced by lookup/randomLookup. */
  typedef void (*LdDiscoFreeStringFn)(void *pluginCtx, char *s);

  /* `record`, when non-NULL, is a pre-signed advertisement to publish
   * verbatim, so the plugin can advertise this node's identity from its own
   * discovery node. */
  typedef int (*LdDiscoStartAdvertisingFn)(void *pluginCtx,
                                           const char *key,
                                           const uint8_t *data,
                                           size_t dataLen,
                                           const uint8_t *record,
                                           size_t recordLen,
                                           char *errBuf,
                                           size_t errBufLen);

  typedef int (*LdDiscoStopAdvertisingFn)(void *pluginCtx,
                                          const char *key,
                                          char *errBuf,
                                          size_t errBufLen);

  typedef int (*LdDiscoRegisterInterestFn)(void *pluginCtx,
                                           const char *key,
                                           char *errBuf,
                                           size_t errBufLen);

  typedef int (*LdDiscoUnregisterInterestFn)(void *pluginCtx,
                                             const char *key,
                                             char *errBuf,
                                             size_t errBufLen);

  /* Bootstrap entries are backend-native strings: full multiaddrs including
   * /p2p/<peerId>. A partial failure should be reported as LD_DISCO_ERROR
   * with the failing entry named in errBuf. */
  typedef int (*LdDiscoAddBootstrapEntriesFn)(void *pluginCtx,
                                              const char *const *entries,
                                              size_t entriesLen,
                                              char *errBuf,
                                              size_t errBufLen);

  /* The vtable the plugin registers. Every function pointer must be set; a
   * plugin that cannot support a verb should install an entry that returns
   * LD_DISCO_ERROR. */
  typedef struct
  {
    uint32_t abiVersion; /* must be LD_DISCO_ABI_VERSION */
    void *pluginCtx;     /* opaque, passed back to every entry point */

    /* How long logos-delivery waits for one verb before giving up on it.
     * The plugin owns this value because only the plugin knows how slow its
     * operations can be. 0 selects the built-in default. Note that a verb
     * that exceeds it is abandoned by the caller, not interrupted: the entry
     * point keeps running to completion on the discovery thread. */
    uint32_t requestTimeoutMs;

    LdDiscoStartFn start;
    LdDiscoStopFn stop;
    LdDiscoLookupFn lookup;
    LdDiscoRandomLookupFn randomLookup;
    LdDiscoFreeStringFn freeString;
    LdDiscoStartAdvertisingFn startAdvertising;
    LdDiscoStopAdvertisingFn stopAdvertising;
    LdDiscoRegisterInterestFn registerInterest;
    LdDiscoUnregisterInterestFn unregisterInterest;
    LdDiscoAddBootstrapEntriesFn addBootstrapEntries;
  } LdServiceDiscoveryPlugin;

  /* ------------------------------------------------------ registration -- */

  /*
   * Registration is asynchronous, like every other logos-delivery entry point.
   * It has to be: the request is served on the node's own thread, and the host
   * calls in from its own. The vtable therefore travels as an address rather
   * than as a value --
   *   int logosdelivery_set_service_discovery_plugin(
   *       void *ctx, LogosDeliveryScalarRawFn cb, void *user_data,
   *       uint64_t pluginPtr);
   * declared in the generated header. Use the typed wrappers below instead of
   * casting by hand.
   *
   * Lifetime: logos-delivery copies the struct while serving the request, so
   * `plugin` must stay alive and unmodified until on_reply fires. A static or
   * heap-allocated struct is the simple choice; a stack one is only safe if the
   * caller blocks until the reply.
   *
   * Outcome arrives on on_reply: err_code == 0 means installed. It fails when
   * the ABI version does not match, an entry point is NULL, or the node was not
   * configured for external discovery -- in that last case no backend exists to
   * serve the request, and err_msg says no provider is registered. Replacing
   * this node's installed plugin is allowed; it never touches another node's.
   */

  /* Installs (or replaces) the plugin for the node identified by `ctx` (the
   * handle returned by logosdelivery_create_node). Takes a typed plugin
   * pointer so the caller never casts. */
  static inline int logosdelivery_install_service_discovery_plugin(
      void *ctx,
      const LdServiceDiscoveryPlugin *plugin,
      LogosDeliveryScalarRawFn callback,
      void *user_data)
  {
    return logosdelivery_set_service_discovery_plugin(
        ctx, callback, user_data, (uint64_t)(uintptr_t)plugin);
  }

  /* Removes this node's plugin; its discovery verbs fail until a new one is
   * installed, and other nodes are unaffected. Declared in the generated
   * header as
   *   int logosdelivery_clear_service_discovery_plugin(
   *       void *ctx, LogosDeliveryScalarRawFn cb, void *user_data);
   *
   * Hosts that hold the LogosDeliveryCtx wrapper rather than a raw handle can
   * use the generated logosdelivery_ctx_set_service_discovery_plugin /
   * logosdelivery_ctx_clear_service_discovery_plugin helpers instead; the
   * former takes the plugin address as a uint64_t. */

#ifdef __cplusplus
}
#endif

#endif /* __logosdelivery_service_discovery__ */
