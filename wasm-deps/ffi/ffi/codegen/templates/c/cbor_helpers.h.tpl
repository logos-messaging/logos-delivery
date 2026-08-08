#ifndef NIM_FFI_CBOR_HELPERS_H_INCLUDED
#define NIM_FFI_CBOR_HELPERS_H_INCLUDED
/* Leaf CBOR codecs (scalars, text strings, byte strings) plus the buffer
 * drivers. The per-struct / per-container codecs in the library header call
 * into these by name (C has no overloading, so each leaf gets a distinct
 * nimffi_enc_* / nimffi_dec_* symbol). Guarded so two nim-ffi headers can
 * share a translation unit. */
#include "nim_ffi_prelude.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Result delivery callback exported by the Nim dylib: `ret` is 0 on success
 * (then `msg`/`len` carry the CBOR response) or non-zero on failure (then
 * `msg`/`len` carry the error text, which is NOT NUL-terminated). */
typedef void (*FFICallback)(int ret, const char* msg, size_t len, void* user_data);

/* Return / callback status codes. NIMFFI_RET_OK (0) is success; any non-zero
 * value handed to a result callback's `err_code` (or returned by a submit call)
 * is a failure. NIMFFI_RET_MISSING_CALLBACK is a special case from the Nim
 * dispatcher: the callback will never fire, so the request path must report the
 * failure itself.
 *
 * NIMFFI_RET_STALE_WARN is the one NON-terminal code: nim-ffi delivers it every
 * ~5s while a handler is still running (with `msg`/`len` carrying the elapsed
 * milliseconds as decimal text), then still ends with a terminal RET_OK/RET_ERR.
 * A caller that only wants the final answer must ignore it, not treat it as an
 * error. */
#define NIMFFI_RET_OK 0
#define NIMFFI_RET_ERROR 1
#define NIMFFI_RET_MISSING_CALLBACK 2
#define NIMFFI_RET_STALE_WARN 3

/* ── leaf encoders ─────────────────────────────────────────────────────── */
static inline CborError nimffi_enc_bool(CborEncoder* e, const bool* v) {
    return cbor_encode_boolean(e, *v);
}
static inline CborError nimffi_enc_i64(CborEncoder* e, const int64_t* v) {
    return cbor_encode_int(e, *v);
}
static inline CborError nimffi_enc_i32(CborEncoder* e, const int32_t* v) {
    return cbor_encode_int(e, (int64_t)*v);
}
static inline CborError nimffi_enc_i16(CborEncoder* e, const int16_t* v) {
    return cbor_encode_int(e, (int64_t)*v);
}
static inline CborError nimffi_enc_i8(CborEncoder* e, const int8_t* v) {
    return cbor_encode_int(e, (int64_t)*v);
}
static inline CborError nimffi_enc_u64(CborEncoder* e, const uint64_t* v) {
    return cbor_encode_uint(e, *v);
}
static inline CborError nimffi_enc_u32(CborEncoder* e, const uint32_t* v) {
    return cbor_encode_uint(e, (uint64_t)*v);
}
static inline CborError nimffi_enc_u16(CborEncoder* e, const uint16_t* v) {
    return cbor_encode_uint(e, (uint64_t)*v);
}
static inline CborError nimffi_enc_u8(CborEncoder* e, const uint8_t* v) {
    return cbor_encode_uint(e, (uint64_t)*v);
}
static inline CborError nimffi_enc_f64(CborEncoder* e, const double* v) {
    return cbor_encode_double(e, *v);
}
static inline CborError nimffi_enc_f32(CborEncoder* e, const float* v) {
    return cbor_encode_float(e, *v);
}
static inline CborError nimffi_enc_str(CborEncoder* e, const NimFfiStr* v) {
    return cbor_encode_text_string(e, v->data ? v->data : "", v->len);
}
static inline CborError nimffi_enc_bytes(CborEncoder* e, const NimFfiBytes* v) {
    return cbor_encode_byte_string(e, v->data, v->len);
}

/* ── leaf decoders ─────────────────────────────────────────────────────── */
/* After reading a leaf, the parser must advance past it; both steps
 * short-circuit on the same CborError, so they travel together. */
static inline CborError nimffi_advance_if_ok(CborValue* it, CborError err) {
    if (err) {
        return err;
    }
    return cbor_value_advance(it);
}

static inline CborError nimffi_dec_bool(CborValue* it, bool* out) {
    if (!cbor_value_is_boolean(it)) {
        return CborErrorImproperValue;
    }
    return nimffi_advance_if_ok(it, cbor_value_get_boolean(it, out));
}
static inline CborError nimffi_dec_i64(CborValue* it, int64_t* out) {
    if (!cbor_value_is_integer(it)) {
        return CborErrorImproperValue;
    }
    return nimffi_advance_if_ok(it, cbor_value_get_int64_checked(it, out));
}
static inline CborError nimffi_dec_i32(CborValue* it, int32_t* out) {
    int64_t tmp = 0;
    CborError err = nimffi_dec_i64(it, &tmp);
    if (err) {
        return err;
    }
    if (tmp < INT32_MIN || tmp > INT32_MAX) {
        return CborErrorDataTooLarge;
    }
    *out = (int32_t)tmp;
    return CborNoError;
}
static inline CborError nimffi_dec_i16(CborValue* it, int16_t* out) {
    int64_t tmp = 0;
    CborError err = nimffi_dec_i64(it, &tmp);
    if (err) {
        return err;
    }
    if (tmp < INT16_MIN || tmp > INT16_MAX) {
        return CborErrorDataTooLarge;
    }
    *out = (int16_t)tmp;
    return CborNoError;
}
static inline CborError nimffi_dec_i8(CborValue* it, int8_t* out) {
    int64_t tmp = 0;
    CborError err = nimffi_dec_i64(it, &tmp);
    if (err) {
        return err;
    }
    if (tmp < INT8_MIN || tmp > INT8_MAX) {
        return CborErrorDataTooLarge;
    }
    *out = (int8_t)tmp;
    return CborNoError;
}
static inline CborError nimffi_dec_u64(CborValue* it, uint64_t* out) {
    if (!cbor_value_is_unsigned_integer(it)) {
        return CborErrorImproperValue;
    }
    return nimffi_advance_if_ok(it, cbor_value_get_uint64(it, out));
}
static inline CborError nimffi_dec_u32(CborValue* it, uint32_t* out) {
    uint64_t tmp = 0;
    CborError err = nimffi_dec_u64(it, &tmp);
    if (err) {
        return err;
    }
    if (tmp > UINT32_MAX) {
        return CborErrorDataTooLarge;
    }
    *out = (uint32_t)tmp;
    return CborNoError;
}
static inline CborError nimffi_dec_u16(CborValue* it, uint16_t* out) {
    uint64_t tmp = 0;
    CborError err = nimffi_dec_u64(it, &tmp);
    if (err) {
        return err;
    }
    if (tmp > UINT16_MAX) {
        return CborErrorDataTooLarge;
    }
    *out = (uint16_t)tmp;
    return CborNoError;
}
static inline CborError nimffi_dec_u8(CborValue* it, uint8_t* out) {
    uint64_t tmp = 0;
    CborError err = nimffi_dec_u64(it, &tmp);
    if (err) {
        return err;
    }
    if (tmp > UINT8_MAX) {
        return CborErrorDataTooLarge;
    }
    *out = (uint8_t)tmp;
    return CborNoError;
}
static inline CborError nimffi_dec_f64(CborValue* it, double* out) {
    if (cbor_value_is_double(it)) {
        return nimffi_advance_if_ok(it, cbor_value_get_double(it, out));
    }
    if (cbor_value_is_float(it)) {
        float f = 0.0f;
        CborError err = cbor_value_get_float(it, &f);
        if (err) {
            return err;
        }
        *out = (double)f;
        return cbor_value_advance(it);
    }
    return CborErrorImproperValue;
}
static inline CborError nimffi_dec_f32(CborValue* it, float* out) {
    if (cbor_value_is_float(it)) {
        return nimffi_advance_if_ok(it, cbor_value_get_float(it, out));
    }
    if (cbor_value_is_double(it)) {
        double d = 0.0;
        CborError err = cbor_value_get_double(it, &d);
        if (err) {
            return err;
        }
        *out = (float)d;
        return cbor_value_advance(it);
    }
    return CborErrorImproperValue;
}
static inline CborError nimffi_dec_str(CborValue* it, NimFfiStr* out) {
    if (!cbor_value_is_text_string(it)) {
        return CborErrorImproperValue;
    }
    size_t len = 0;
    CborError err = cbor_value_get_string_length(it, &len);
    if (err) {
        return err;
    }
    if (len == SIZE_MAX) { /* len + 1 would wrap to a 0-byte allocation */
        return CborErrorDataTooLarge;
    }
    /* one extra byte so a NUL-free payload is a valid C string */
    out->data = (char*)malloc(len + 1);
    if (!out->data) {
        return CborErrorOutOfMemory;
    }
    out->len = len;
    size_t copied = len;
    err = cbor_value_copy_text_string(it, out->data, &copied, NULL);
    if (err) {
        free(out->data);
        out->data = NULL;
        out->len = 0;
        return err;
    }
    out->data[len] = '\0';
    return cbor_value_advance(it);
}
static inline CborError nimffi_dec_bytes(CborValue* it, NimFfiBytes* out) {
    if (!cbor_value_is_byte_string(it)) {
        return CborErrorImproperValue;
    }
    size_t len = 0;
    CborError err = cbor_value_get_string_length(it, &len);
    if (err) {
        return err;
    }
    out->data = (uint8_t*)malloc(len ? len : 1);
    if (!out->data) {
        return CborErrorOutOfMemory;
    }
    out->len = len;
    size_t copied = len;
    err = cbor_value_copy_byte_string(it, out->data, &copied, NULL);
    if (err) {
        free(out->data);
        out->data = NULL;
        out->len = 0;
        return err;
    }
    return cbor_value_advance(it);
}

/* ── buffer drivers ────────────────────────────────────────────────────── */
typedef CborError (*nimffi_enc_fn)(CborEncoder*, const void*);
typedef CborError (*nimffi_dec_fn)(CborValue*, void*);

static inline char* nimffi_dup_cstr(const char* s) {
    size_t n = strlen(s) + 1;
    char* p = (char*)malloc(n);
    if (p) {
        memcpy(p, s, n);
    }
    return p;
}

/* NUL-terminated copy of a length-delimited (not NUL-terminated) byte run,
 * for turning the FFICallback's raw error `msg`/`len` into a C string; NULL if
 * it can't. */
static inline char* nimffi_dup_cstr_n(const char* s, size_t n) {
    if (n == SIZE_MAX) {
        return NULL;
    }
    char* p = (char*)malloc(n + 1);
    if (p) {
        if (n > 0) {
            memcpy(p, s, n);
        }
        p[n] = '\0';
    }
    return p;
}

/* Encode `val` with `fn` into a freshly malloc'd buffer, doubling on overflow.
 * Returns 0 and sets out/outlen on success; -1 and *err (heap) on failure. */
static inline int nimffi_encode_to_buf(
        nimffi_enc_fn fn, const void* val,
        uint8_t** out, size_t* outlen, char** err) {
    size_t cap = 4096;
    uint8_t* buf = (uint8_t*)malloc(cap);
    if (!buf) {
        if (err) *err = nimffi_dup_cstr("out of memory");
        return -1;
    }
    for (;;) {
        CborEncoder enc;
        cbor_encoder_init(&enc, buf, cap, 0);
        CborError e = fn(&enc, val);
        if (e == CborNoError) {
            *outlen = cbor_encoder_get_buffer_size(&enc, buf);
            *out = buf;
            return 0;
        }
        if (e == CborErrorOutOfMemory) {
            size_t extra = cbor_encoder_get_extra_bytes_needed(&enc);
            cap += extra > 0 ? extra : cap;
            uint8_t* grown = (uint8_t*)realloc(buf, cap);
            if (!grown) {
                free(buf);
                if (err) *err = nimffi_dup_cstr("out of memory");
                return -1;
            }
            buf = grown;
            continue;
        }
        free(buf);
        if (err) *err = nimffi_dup_cstr(cbor_error_string(e));
        return -1;
    }
}

/* Decode a CBOR buffer into `out` with `fn`. Returns 0 on success; -1 and
 * *err (heap) on failure. */
static inline int nimffi_decode_from_buf(
        nimffi_dec_fn fn, const uint8_t* buf, size_t len,
        void* out, char** err) {
    CborParser parser;
    CborValue it;
    CborError e = cbor_parser_init(buf, len, 0, &parser, &it);
    if (e != CborNoError) {
        if (err) *err = nimffi_dup_cstr(cbor_error_string(e));
        return -1;
    }
    e = fn(&it, out);
    if (e != CborNoError) {
        if (err) *err = nimffi_dup_cstr(cbor_error_string(e));
        return -1;
    }
    return 0;
}

#ifdef __cplusplus
}
#endif

#endif /* NIM_FFI_CBOR_HELPERS_H_INCLUDED */
