#pragma once
#ifndef __liblogosdelivery_rln__
#define __liblogosdelivery_rln__
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

/* One typed callback per RLN function. Each dispatches and returns immediately;
   the call completes later via logosdelivery_rln_response with the same req_id.
   Scalar args are passed directly; complex args (config, options, proof) and
   every result are JSON strings. All strings are borrowed for the duration of
   the call — copy before returning.

   req_id is supplied by the library calling the callbacks. It needs to be 
   unique among the requests currently in flight, that lets concurrent calls 
   (including calls made from different threads) be told apart and matched to
   their responses.

   Arg shapes and result_json follow the RLN module's own wire dialect
   (logos-rln-modules, liblogos_rln_module.lidl / docs/wire-binding.md) — the
   host forwards both directions verbatim:
   - start/stop/generate_proof/validate_proof/get_epoch_quota results are the
     module's LogosResult envelope {"success":bool,"value":…,"error":…} where
     a failure's error is the JSON-encoded typed object
     {"class":…,"kind":…,"message":…} (class: not_ready | transient |
     budget_exhausted | permanent).
   - register_membership/get_membership_state results are the module's compact
     JSON reply; failures are the in-band envelope {"error":{"class":…,…}}. */

typedef void (*LogosDeliveryRlnStartFn)(uint64_t req_id, const char* config_json,
                                        void* user_data);

typedef void (*LogosDeliveryRlnStopFn)(uint64_t req_id, void* user_data);

typedef void (*LogosDeliveryRlnRegisterFn)(uint64_t req_id, const char* registry_id,
                                           const char* rln_identifier,
                                           const char* options_json, void* user_data);

typedef void (*LogosDeliveryRlnGetMembershipStateFn)(uint64_t req_id,
                                                     const char* registry_id,
                                                     const char* rln_identifier,
                                                     void* user_data);

typedef void (*LogosDeliveryRlnGetEpochQuotaFn)(uint64_t req_id, const char* registry_id,
                                                const char* rln_identifier,
                                                uint64_t timestamp, void* user_data);

typedef void (*LogosDeliveryRlnGenerateProofFn)(uint64_t req_id, const char* registry_id,
                                                const char* rln_identifier,
                                                const char* signal_hex,
                                                uint64_t timestamp, void* user_data);

typedef void (*LogosDeliveryRlnValidateProofFn)(uint64_t req_id, const char* registry_id,
                                                const char* rln_identifier,
                                                const char* signal_hex, uint64_t timestamp,
                                                const char* proof_json, void* user_data);

typedef struct {
  LogosDeliveryRlnStartFn start;
  LogosDeliveryRlnStopFn stop;
  LogosDeliveryRlnRegisterFn register_membership;
  LogosDeliveryRlnGetMembershipStateFn get_membership_state;
  LogosDeliveryRlnGetEpochQuotaFn get_epoch_quota;
  LogosDeliveryRlnGenerateProofFn generate_proof;
  LogosDeliveryRlnValidateProofFn validate_proof;
} LogosDeliveryRlnCallbacks;

/* The host application registers callbacks once, before node start. NULL clears and fails
   all in-flight requests. Returns 0 on success. */
int logosdelivery_rln_set_callbacks(const LogosDeliveryRlnCallbacks* cbs,
                                    void* user_data);

/* The host application sends the response on completion of an outbound call, same req_id. Thread-safe;
   result_json is copied before return. */
int logosdelivery_rln_response(uint64_t req_id, const char* result_json);

#ifdef __cplusplus
}
#endif
#endif
