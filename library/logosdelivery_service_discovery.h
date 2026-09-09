#ifndef __logosdelivery_service_discovery__
#define __logosdelivery_service_discovery__

#include <stddef.h>
#include <stdint.h>

/* LD_DISCO_ABI_ONLY: only the entry-point typedefs and the vtable struct, no
 * registration helpers. Defined by liblogosdelivery itself to check its Nim
 * mirror of the struct against this header at compile time; hosts never set
 * it. */
#ifndef LD_DISCO_ABI_ONLY
#include "generated/logosdelivery.h"
#endif

/*
 * Service-discovery plugin interface.
 *
 * logos-delivery can delegate peer/service discovery to an external provider.
 * The provider implements the entry points below and registers them with
 * logosdelivery_install_service_discovery_plugin. External discovery is active
 * only when the node is configured for it AND a valid plugin (matching ABI
 * version, no NULL entry point) is registered.
 *
 * Bootstrap peers are the provider's own configuration; logos-delivery never
 * passes them.
 *
 * Calling model:
 *   - Entry points are blocking calls made from the node's discovery thread,
 *     one at a time per node. They may block for as long as the operation
 *     takes. A vtable shared by several nodes must tolerate concurrent calls.
 *   - Lifecycle: start, then lookups and advertisements while the node runs,
 *     then stop.
 *
 * Results:
 *   - Lookups return a plugin-owned JSON array; an empty array means no peers:
 *       [ { "peerId": "16Uiu2...",
 *           "seqNo": 1730000000,
 *           "addrs": ["/ip4/1.2.3.4/tcp/60000"],
 *           "services": [ { "id": "/mix/1.0.0", "data": "<base64>" } ] } ]
 *     logos-delivery releases the string through freeString.
 *
 * Memory:
 *   - Arguments are borrowed for the duration of the call.
 *   - Errors are written into the caller-provided errBuf (NUL-terminated,
 *     truncated to errBufLen).
 *   - Strings are NUL-terminated UTF-8. Byte runs carry an explicit length and
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

  /* `key` is a criteria key ("service:<id>", "topic:<pubsubTopic>",
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

  /* `record`, when non-NULL, is a pre-signed advertisement of this node to
   * publish verbatim. */
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

  /* The vtable the plugin registers. Every function pointer must be set; a
   * plugin that cannot support a verb should install an entry that returns
   * LD_DISCO_ERROR. */
  typedef struct
  {
    uint32_t abiVersion; /* must be LD_DISCO_ABI_VERSION */
    void *pluginCtx;     /* opaque, passed back to every entry point */

    /* Per-verb timeout; 0 selects the built-in default. A verb that exceeds
     * it is abandoned by the caller, not interrupted. */
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
  } LdServiceDiscoveryPlugin;

#ifndef LD_DISCO_ABI_ONLY
  /* ------------------------------------------------------ registration -- */

  /*
   * After createNode, logosdelivery_get_discovery_requirements(ctx, cb,
   * user_data) (generated header) answers with JSON
   *   {"externalServiceDiscovery": bool, "bootstrapNodes": ["/dns4/.../p2p/..."]}
   * telling the host whether a plugin is expected and which DHT peers the
   * node's configuration, presets included, resolved for it.
   *
   * Registration is asynchronous like every logos-delivery entry point: the
   * outcome arrives on the callback, err_code == 0 means installed. The vtable
   * is copied while the request is served, so `plugin` must stay alive and
   * unmodified until the callback fires.
   *
   * Register while the node is stopped; both calls below are refused while
   * discovery runs. A registration belongs to the node: it survives stop/start
   * cycles and is released when the node is destroyed. A node configured for
   * external discovery fails to start without a valid plugin.
   *
   * Registration fails when the ABI version does not match, an entry point is
   * NULL, discovery is running, or the node is not configured for external
   * discovery.
   */

  /* Installs (or replaces) the plugin of the node `ctx`. Typed wrapper over
   * the generated logosdelivery_set_service_discovery_plugin, which takes the
   * plugin address as a uint64_t. */
  static inline int logosdelivery_install_service_discovery_plugin(
      void *ctx,
      const LdServiceDiscoveryPlugin *plugin,
      LogosDeliveryScalarRawFn callback,
      void *user_data)
  {
    return logosdelivery_set_service_discovery_plugin(
        ctx, callback, user_data, (uint64_t)(uintptr_t)plugin);
  }

  /* Removal is logosdelivery_clear_service_discovery_plugin(ctx, cb, user_data)
   * from the generated header; the node cannot start again until a new plugin
   * is installed. Hosts holding a LogosDeliveryCtx can use the generated
   * logosdelivery_ctx_set/clear_service_discovery_plugin helpers instead. */
#endif /* LD_DISCO_ABI_ONLY */

#ifdef __cplusplus
}
#endif

#endif /* __logosdelivery_service_discovery__ */
