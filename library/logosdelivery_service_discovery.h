#ifndef __logosdelivery_service_discovery__
#define __logosdelivery_service_discovery__

#include <stddef.h>
#include <stdint.h>

/*
 * Service-discovery plugin interface.
 *
 * logos-delivery can delegate peer/service discovery to an external provider
 * (today: logos-libp2p-module, driven by glue in logos-delivery-module). The
 * provider implements the entry points below -- one per libp2p service
 * discovery operation -- and registers them with
 * logosdelivery_set_service_discovery_plugin.
 *
 * Calling model:
 *   - Every entry point is a plain blocking request: it performs the work and
 *     returns its result. There are no completion callbacks and no events
 *     from the plugin back into logos-delivery.
 *   - Entry points are invoked on a dedicated discovery thread inside
 *     logos-delivery, never on the node's event loop, so they MAY block for
 *     as long as the operation genuinely takes (a cold DHT bootstrap can run
 *     for tens of seconds).
 *   - Calls are serialized: logos-delivery never invokes two entry points
 *     concurrently, so a plugin need not be reentrant.
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

  /* Installs the plugin for the node identified by `ctx` (the handle returned
   * by logosdelivery_create_node). Returns 0 on success, non-zero when the
   * context is invalid, the ABI version does not match, or an entry point is
   * missing. Replacing an installed plugin is allowed. */
  int logosdelivery_set_service_discovery_plugin(
      void *ctx, const LdServiceDiscoveryPlugin *plugin);

  /* Removes the installed plugin; subsequent discovery verbs fail until a new
   * one is installed. Returns 0 on success. */
  int logosdelivery_clear_service_discovery_plugin(void *ctx);

#ifdef __cplusplus
}
#endif

#endif /* __logosdelivery_service_discovery__ */
