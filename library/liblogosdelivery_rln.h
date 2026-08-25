#pragma once
#ifndef __liblogosdelivery_rln__
#define __liblogosdelivery_rln__
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef void (*LogosDeliveryRlnOpFn)(uint64_t req_id, const char* payload_json,
                                     void* user_data);

typedef struct {
  LogosDeliveryRlnOpFn start;
  LogosDeliveryRlnOpFn stop;
  LogosDeliveryRlnOpFn register_membership; /* "register" is a C++ keyword-adjacent trap */
  LogosDeliveryRlnOpFn get_membership_state;
  LogosDeliveryRlnOpFn get_epoch_quota;
  LogosDeliveryRlnOpFn generate_proof;
  LogosDeliveryRlnOpFn verify_proof;
} LogosDeliveryRlnCallbacks;

/* library ← shell: register once, before node start. NULL clears and fails
   all in-flight requests. Returns 0 on success. */
int logosdelivery_rln_set_callbacks(const LogosDeliveryRlnCallbacks* cbs,
                                    void* user_data);

/* shell → library: completion of an outbound call. Thread-safe; the string
   is copied before return. */
int logosdelivery_rln_response(uint64_t req_id, const char* result_json);

#ifdef __cplusplus
}
#endif
#endif