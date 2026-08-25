// Public C header for the Logos Messaging API (LMAPI) library.
//
// The call surface is generated from the {.ffi.} annotations in library/*.nim
// and written to generated/logosdelivery.h by `make liblogosdelivery`. That file
// is a build artifact, not checked in, so build the library before you compile
// against this header. This file adds what nim-ffi exports but leaves out of the
// `abi = c` header: the event-listener ABI, and the synchronous exports.
#pragma once
#ifndef __liblogosdelivery__
#define __liblogosdelivery__

#include <stddef.h>
#include <stdint.h>

#include "generated/logosdelivery.h"

// Kept as aliases of the generated NIMFFI_RET_* codes so existing callers that
// use the short names keep compiling. Guarded because the legacy libwaku header
// defines the same names with the same values.
#ifndef RET_OK
#define RET_OK NIMFFI_RET_OK
#endif
#ifndef RET_ERR
#define RET_ERR NIMFFI_RET_ERR
#endif
#ifndef RET_MISSING_CALLBACK
#define RET_MISSING_CALLBACK NIMFFI_RET_MISSING_CALLBACK
#endif

#ifdef __cplusplus
extern "C"
{
#endif

  // Version and git commit hash. Needs no ctx. The buffer belongs to the calling
  // thread and lasts until that thread calls this again, so copy it.
  const char *logosdelivery_version(void);

  // Raw result-delivery callback used by the event API. `msg` is a byte run of
  // `len` bytes, not NUL-terminated, and is valid only for the duration of the
  // call.
  typedef void (*FFICallBack)(int callerRet, const char *msg, size_t len, void *userData);

  // Events are delivered through a per-event listener registry. Register one
  // callback per event name of interest; see the README for the full list.
  // Channel lifecycle events are "onChannelMessageReceived" (payload
  // base64-encoded), "onChannelMessageSent" and "onChannelMessageError".

  // Registers a callback for the named event and returns a non-zero listener id
  // (0 on an invalid context). `ctx` is the context handle returned by
  // logosdelivery_create_node.
  // The callback runs on a dedicated event thread and must be fast,
  // non-blocking and thread-safe.
  uint64_t logosdelivery_add_event_listener(void *ctx,
                                            const char *eventName,
                                            FFICallBack callback,
                                            void *userData);

  // Removes a previously registered listener. Returns 0 on success, 1 if the
  // listener id was not found or the context is invalid.
  int logosdelivery_remove_event_listener(void *ctx,
                                          uint64_t listenerId);

// Net backend ABI. A module that owns a libp2p node registers a backend under a
// name, and a node created with "libp2pProvider": "<name>" runs its Edge
// protocols over that node instead of its own libp2p stack.
#define LOGOSDELIVERY_NET_BACKEND_ABI_VERSION 1

  // Called on the library thread with {"op": "<name>", "args": {...}} and must
  // return at once. Every request gets exactly one
  // logosdelivery_net_backend_respond, from any thread.
  typedef void (*LogosDeliveryNetSubmitFn)(uint64_t requestId,
                                           const char *opJson,
                                           size_t opLen,
                                           void *userData);

  typedef struct
  {
    uint32_t version;
    LogosDeliveryNetSubmitFn submit;
  } LogosDeliveryNetBackendTable;

  // Registers (or replaces) the backend named `name`. Returns 0 on success, and
  // non-zero for a null argument, an unsupported version, a name longer than 63
  // characters, or a full backend registry.
  int logosdelivery_register_net_backend(const char *name,
                                         const LogosDeliveryNetBackendTable *table,
                                         void *userData);

  // Answers one submitted op. `ok != 0` carries the result JSON in `data`, and
  // `ok == 0` carries the error text. The library copies `data` before
  // returning. Returns 0 when the answer reaches the library thread.
  int logosdelivery_net_backend_respond(uint64_t requestId,
                                        int ok,
                                        const char *data,
                                        size_t len);

#ifdef __cplusplus
}
#endif

#endif /* __liblogosdelivery__ */
