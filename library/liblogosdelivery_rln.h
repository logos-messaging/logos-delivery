#pragma once
#ifndef __liblogosdelivery_rln__
#define __liblogosdelivery_rln__
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

/* One typed callback per RLN operation the node performs. Each dispatches and
   returns immediately; the call completes later via logosdelivery_rln_response
   with the same req_id. Scalar args are passed directly; complex args (proof)
   and every result are JSON strings. All strings are borrowed for the duration
   of the call — copy before returning.

   The plugin is implementation-agnostic: the library never names a membership,
   a registry or an epoch size, and never starts or configures the backend. The
   host owns all of that and supplies whatever its implementation needs when it
   forwards a call.

   result_json follows the RLN module API's own wire dialect (logos-rln-modules,
   liblogos_rln_module.lidl / docs/wire-binding.md), forwarded verbatim:
   - get_epoch_quota/generate_proof/validate_proof results are the LogosResult
     envelope {"success":bool,"value":…,"error":…} where a failure's error is
     the JSON-encoded typed object {"class":…,"kind":…,"message":…}
     (class: not_ready | transient | budget_exhausted | permanent).
   - get_membership_state results are the compact JSON reply; failures are the
     in-band envelope {"error":{"class":…,…}}. */

typedef void (*LogosDeliveryRlnGetMembershipStateFn)(uint64_t req_id, void* user_data);

typedef void (*LogosDeliveryRlnGetEpochQuotaFn)(uint64_t req_id, uint64_t timestamp,
                                                void* user_data);

typedef void (*LogosDeliveryRlnGenerateProofFn)(uint64_t req_id, const char* signal_hex,
                                                uint64_t timestamp, void* user_data);

typedef void (*LogosDeliveryRlnValidateProofFn)(uint64_t req_id, const char* signal_hex,
                                                uint64_t timestamp,
                                                const char* proof_json, void* user_data);

typedef struct {
  LogosDeliveryRlnGetMembershipStateFn get_membership_state;
  LogosDeliveryRlnGetEpochQuotaFn get_epoch_quota;
  LogosDeliveryRlnGenerateProofFn generate_proof;
  LogosDeliveryRlnValidateProofFn validate_proof;
} LogosDeliveryRlnPlugin;

/* The host application installs the plugin once, before node creation: an
   installed plugin is what enables RLN over it. NULL clears the plugin and
   fails all in-flight requests. Returns 0 on success. */
int logosdelivery_rln_set_plugin(const LogosDeliveryRlnPlugin* plugin,
                                 void* user_data);

/* The host application sends the response on completion of an outbound call, same req_id. Thread-safe;
   result_json is copied before return. */
int logosdelivery_rln_response(uint64_t req_id, const char* result_json);

#ifdef __cplusplus
}
#endif
#endif
