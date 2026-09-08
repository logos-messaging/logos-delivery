#pragma once
#ifndef __liblogosdelivery_rln__
#define __liblogosdelivery_rln__
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

/* External RLN plugin over a blocking vtable. The library owns all threading:
   every entry point is called from a library worker thread and BLOCKS until
   done. The plugin needs no queues, callbacks, or request ids.

   - timeout_ms is the library's remaining budget for this call — the single
     timekeeper. The plugin caps its own internal waits with it and may
     return LD_RLN_TIMEOUT immediately if it cannot fit.
   - rc != LD_RLN_OK is a transport failure: no answer was obtained. Put a
     human-readable reason in err_buf (NUL-terminated, truncated to
     err_buf_len). Domain outcomes (invalid proof, budget exhausted, …) are
     NOT transport failures: they ride inside *out_json with rc = LD_RLN_OK.
   - On LD_RLN_OK, *out_json is a plugin-owned NUL-terminated buffer; the
     library copies it and hands it back via free_string on the same thread.
   - const char* arguments are borrowed for the duration of the call.
   - Concurrency: at most one call per vtable slot at a time, but different
     slots are called concurrently from different worker threads.

   Arg shapes and *out_json follow the RLN module's own wire dialect
   (logos-rln-modules, liblogos_rln_module.lidl / docs/wire-binding.md) — the
   plugin forwards both directions verbatim:
   - start/stop/generate_proof/validate_proof/get_epoch_quota results are the
     module's LogosResult envelope {"success":bool,"value":…,"error":…} where
     a failure's error is the JSON-encoded typed object
     {"class":…,"kind":…,"message":…} (class: not_ready | transient |
     budget_exhausted | permanent).
   - register_membership/get_membership_state results are the module's compact
     JSON reply; failures are the in-band envelope {"error":{"class":…,…}}. */

#define LD_RLN_PLUGIN_ABI_VERSION 1

#define LD_RLN_OK 0
#define LD_RLN_NOT_READY 1 /* plugin/module not initialized or not started */
#define LD_RLN_TIMEOUT 2   /* could not answer within timeout_ms */
#define LD_RLN_INTERNAL 3  /* anything else; detail in err_buf */

typedef struct LdRlnPlugin {
  uint32_t abi_version; /* LD_RLN_PLUGIN_ABI_VERSION; checked at install */
  void* plugin_ctx;     /* carried back as the first argument of every call */

  int32_t (*start)(void* plugin_ctx, const char* config_json,
                   uint32_t timeout_ms, char** out_json, char* err_buf,
                   size_t err_buf_len);
  int32_t (*stop)(void* plugin_ctx, uint32_t timeout_ms, char** out_json,
                  char* err_buf, size_t err_buf_len);
  int32_t (*register_membership)(void* plugin_ctx, const char* registry_id,
                                 const char* rln_identifier,
                                 const char* options_json, uint32_t timeout_ms,
                                 char** out_json, char* err_buf,
                                 size_t err_buf_len);
  int32_t (*get_membership_state)(void* plugin_ctx, const char* registry_id,
                                  const char* rln_identifier,
                                  uint32_t timeout_ms, char** out_json,
                                  char* err_buf, size_t err_buf_len);
  int32_t (*get_epoch_quota)(void* plugin_ctx, const char* registry_id,
                             const char* rln_identifier, uint64_t timestamp,
                             uint32_t timeout_ms, char** out_json,
                             char* err_buf, size_t err_buf_len);
  int32_t (*generate_proof)(void* plugin_ctx, const char* registry_id,
                            const char* rln_identifier, const char* signal_hex,
                            uint64_t timestamp, uint32_t timeout_ms,
                            char** out_json, char* err_buf,
                            size_t err_buf_len);
  int32_t (*validate_proof)(void* plugin_ctx, const char* registry_id,
                            const char* rln_identifier, const char* signal_hex,
                            uint64_t timestamp, const char* proof_json,
                            uint32_t timeout_ms, char** out_json,
                            char* err_buf, size_t err_buf_len);

  void (*free_string)(void* plugin_ctx, char* s);
} LdRlnPlugin;

/* Installed via the logosdelivery_set_rln_plugin / logosdelivery_clear_rln_plugin
   FFI entry points (see liblogosdelivery.h): the plugin passes the struct's
   address; the library validates and copies it. The struct is borrowed only
   for the duration of the install call. */

#ifdef __cplusplus
}
#endif

#endif /* __liblogosdelivery_rln__ */
