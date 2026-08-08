#ifndef NIM_FFI_PRELUDE_H_INCLUDED
#define NIM_FFI_PRELUDE_H_INCLUDED
/* Generated C binding for a nim-ffi library. Requests/responses travel as
 * CBOR (encoded with vendored TinyCBOR on this side, matching the Nim-side
 * cbor_serial codec on the wire — both ends speak RFC 8949).
 *
 * The API is asynchronous: every method/constructor takes a result callback
 * and returns immediately. The callback fires exactly once — synchronously on
 * a submit-time failure, otherwise from the Nim dispatch thread when the reply
 * arrives.
 *
 * Memory ownership contract:
 *   - Request-side strings/sequences are *borrowed*: the binding only reads
 *     them while encoding, so a string literal wrapped with nimffi_str() is
 *     fine and is never freed by the binding.
 *   - Response values and error strings passed into a result callback are
 *     *owned by the binding* and valid only for the duration of that callback;
 *     the binding reclaims them once the callback returns. The caller never
 *     frees them. (The generated <lib>_free_<Type>() helpers are internal — the
 *     trampolines use them to reclaim decoded payloads.)
 *   - A context handle delivered to a constructor callback is the exception:
 *     ownership transfers to the caller, who releases it with
 *     <lib>_ctx_destroy(). It is a lifecycle handle, not returned data.
 *
 * Trust boundary: the decoders assume the CBOR they parse was produced by the
 * paired Nim library. They reject malformed input rather than trusting it, but
 * they are not hardened against a hostile peer feeding crafted payloads through
 * the raw nimffi_decode_from_buf entry point.
 */
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <tinycbor/cbor.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Owned, length-delimited UTF-8 text (Nim `string`/`cstring`). On the request
 * side `data` may point at borrowed storage (see nimffi_str); on the response
 * side it is heap-allocated and freed by nimffi_free_str. Always NUL-padded by
 * one byte after decode so `data` is usable as a C string when it has no
 * embedded NULs. */
typedef struct {
    char* data;
    size_t len;
} NimFfiStr;

/* Owned, length-delimited byte buffer (Nim `seq[byte]`). */
typedef struct {
    uint8_t* data;
    size_t len;
} NimFfiBytes;

/* Wrap a borrowed C string for use as a request field. The returned view is
 * not owned by the binding and must outlive the call that encodes it. */
static inline NimFfiStr nimffi_str(const char* s) {
    NimFfiStr v;
    v.data = (char*)s;
    v.len = s ? strlen(s) : 0;
    return v;
}

static inline void nimffi_free_str(NimFfiStr* v) {
    if (!v || !v->data) {
        return;
    }
    free(v->data);
    v->data = NULL;
    v->len = 0;
}

static inline void nimffi_free_bytes(NimFfiBytes* v) {
    if (!v || !v->data) {
        return;
    }
    free(v->data);
    v->data = NULL;
    v->len = 0;
}

#ifdef __cplusplus
}
#endif

#endif /* NIM_FFI_PRELUDE_H_INCLUDED */
