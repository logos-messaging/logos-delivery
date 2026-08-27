#pragma once
#ifndef __liblogosdelivery_rln__
#define __liblogosdelivery_rln__
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

/* One typed callback per RLN function. Each dispatches and returns immediately;
   the call completes later via logosdelivery_rln_response with the same req_id.
   Scalar args are passed directly; complex args (options, proof) and every
   result are JSON strings (see rln-wire-schema.md). All strings are borrowed for
   the duration of the call — copy before returning. */

typedef void (*LogosDeliveryRlnStartFn)(uint64_t req_id, void* user_data);

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
  LogosDeliveryRlnRegisterFn register_membership; /* "register" is a C++ keyword-adjacent trap */
  LogosDeliveryRlnGetMembershipStateFn get_membership_state;
  LogosDeliveryRlnGetEpochQuotaFn get_epoch_quota;
  LogosDeliveryRlnGenerateProofFn generate_proof;
  LogosDeliveryRlnValidateProofFn validate_proof;
} LogosDeliveryRlnCallbacks;

/* library ← shell: register once, before node start. NULL clears and fails
   all in-flight requests. Returns 0 on success. */
int logosdelivery_rln_set_callbacks(const LogosDeliveryRlnCallbacks* cbs,
                                    void* user_data);

/* shell → library: completion of an outbound call, same req_id. Thread-safe;
   result_json is copied before return. */
int logosdelivery_rln_response(uint64_t req_id, const char* result_json);

#ifdef __cplusplus
}
#endif
#endif
