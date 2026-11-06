#pragma once
#ifndef __liblogosdelivery_libp2p__
#define __liblogosdelivery_libp2p__
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

/* "Host" below is the application embedding this library over its C ABI and
   installing the module — logos-delivery-module in a Logos Core deployment.

   The libp2p stack (host and pubsub) can be provided by a Logos module instead
   of the nim-libp2p linked into this library. The node configuration names the
   implementation (`libp2p-impl`: "builtin", or the module's name); the host
   installs the matching module once, before node creation. Installing a module
   while the configuration says "builtin", or the reverse, is a startup error.

   The wire contract is the CBOR request/event set of
   logos_delivery/waku/libp2p_iface/module_contract.nim: every payload is a
   plain value (bytes, strings, integers, floats, booleans, objects and
   sequences of those); peer ids and multiaddresses are strings, streams are
   opaque uint64 handles. Each request maps onto a nim-ffi `{.ffi.}` request and
   each event onto a `{.ffiEvent.}`.

   Requests: the library calls `call` with a method name and a CBOR payload. The
   host returns immediately and answers later through
   logosdelivery_libp2p_response with the same req_id. All pointers are borrowed
   for the duration of the call — copy before returning.

   Events: the host reports module events through logosdelivery_libp2p_event.
   Validation is on the relay hot path: the module emits "pubsub.validate" and
   the library answers with the "pubsub.validation_verdict" request; a message
   without a verdict within 2000 ms must be treated as ignored. */

#define LD_LIBP2P_ABI_VERSION 1

typedef void (*LogosDeliveryLibp2pCallFn)(uint64_t req_id, const char* method,
                                          const uint8_t* request, size_t request_len,
                                          void* user_data);

typedef struct {
  uint32_t abi_version; /* LD_LIBP2P_ABI_VERSION */
  const char* name;     /* the module's name, compared with `libp2p-impl` */
  LogosDeliveryLibp2pCallFn call;
} LogosDeliveryLibp2pModule;

/* Installs the module once, before node creation. NULL clears it and fails all
   in-flight requests. Returns 0 on success, 2 on an ABI version mismatch. */
int logosdelivery_libp2p_set_module(const LogosDeliveryLibp2pModule* module,
                                    void* user_data);

/* Answers a request. status 0: payload is the CBOR result; otherwise it is a
   UTF-8 error message. Thread-safe; the payload is copied before return.
   Returns non-zero for an unknown req_id (a late answer after a timeout). */
int logosdelivery_libp2p_response(uint64_t req_id, int status, const uint8_t* payload,
                                  size_t payload_len);

/* Reports a module event. Thread-safe; name and payload are copied before
   return. Returns non-zero when no module is installed. */
int logosdelivery_libp2p_event(const char* name, const uint8_t* payload,
                              size_t payload_len);

#ifdef __cplusplus
}
#endif
#endif
