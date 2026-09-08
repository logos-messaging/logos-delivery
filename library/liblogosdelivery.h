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
  // base64-encoded), "onChannelMessageSent", "onChannelMessageError" and
  // "onChannelMessageLost" (payloadHash hex-encoded).

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

  // ---------------------------------------------------------------------
  // Per-channel encryption
  //
  // A channel with no cipher registered sends and receives plaintext. Once
  // registered, the pair is used for every send, every SDS repair
  // rebroadcast and every receive on that channel, and a failure fails the
  // message -- there is no fallback to plaintext.

  // How your callback returns its result. The bytes are copied before it
  // returns, so pass a stack array, a reused scratch buffer, or memory you
  // free right after -- you never allocate anything we take ownership of,
  // and you never ask how much room we have.
  //
  // Call it one or more times; the pieces are concatenated in order, so a
  // cipher can emit nonce, ciphertext and tag separately. Call it with
  // out_len 0 if the result really is zero bytes: returning success without
  // calling it at all fails the message.
  typedef void (*LogosDeliveryCryptoSink)(const uint8_t *out,
                                          size_t out_len,
                                          void *sink_ctx);

  // Transform `in` (`in_len` bytes, NULL when in_len is 0), pass the result
  // to `sink` with the `sink_ctx` you were handed, and return 0. Return
  // non-zero to fail the message; the code appears in the error event.
  //
  // Invoked inline on the node's event loop:
  //   - must be fast and non-blocking; I/O here wedges the node;
  //   - must not call any logosdelivery_* function (rejected as re-entrant);
  //   - `sink`/`sink_ctx` are valid only for the duration of the call.
  //
  // One application message can mean several encrypt calls, one per
  // segment, and decrypt sees them in whatever order the network delivers.
  // So each output must carry what decrypting it needs (a nonce, a key id):
  // a cipher whose state depends on invocation order will desync.
  typedef int (*LogosDeliveryCryptoFn)(const uint8_t *in,
                                       size_t in_len,
                                       LogosDeliveryCryptoSink sink,
                                       void *sink_ctx,
                                       void *user_data);

  // Registering does not require the channel to exist (register first to
  // encrypt from the very first message), and it SURVIVES
  // logosdelivery_channel_close -- closing is reversible, so a re-created
  // channel must not come back up in the clear.
  //
  // `user_data` lifetime: neither a clear nor a stop waits for sends that
  // are already in flight -- a clear only stops NEW messages picking the
  // cipher up, and stopping the node drops the registrations without
  // draining the sends that captured them. Free `user_data` only after
  // logosdelivery_destroy returns, which drains in-flight handlers.

  //
  // nim-ffi has no function-pointer parameter kind, so pass the two
  // LogosDeliveryCryptoFn pointers and `user_data` as uint64_t, e.g.
  // (uint64_t)(uintptr_t)my_encrypt, in the fields of
  // LogosdeliveryChannelSetEncryptionReq (see generated/logosdelivery.h).

#ifdef __cplusplus
}
#endif

#endif /* __liblogosdelivery__ */
