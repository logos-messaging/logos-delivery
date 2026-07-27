#ifndef CBOR_HELPERS_H
#define CBOR_HELPERS_H

#include <stddef.h>
#include <stdint.h>

// Minimal deterministic-CBOR helpers tailored to the small subset of payloads
// the liblogosdelivery FFI uses on the wire:
//   - request bodies: a CBOR map with one entry { "<field>": "<value>" }
//     or, for empty-param procs, { "_placeholder": 0 }
//   - response bodies: a single CBOR text string (the user-returned `string`)
// Anything more elaborate (nested maps, arrays, integer keys) is intentionally
// out of scope.

// Compute the encoded size of `{ "<key>": "<val>" }` with both sides as
// text strings.
size_t cbor_size_map1_tstr_tstr(const char *key, const char *val);

// Encode `{ "<key>": "<val>" }` into `buf` (cap bytes). Writes the actual
// length into *out_written. Returns 0 on success, -1 if the buffer is too
// small or any argument is NULL.
int cbor_encode_map1_tstr_tstr(uint8_t *buf, size_t cap,
                               const char *key, const char *val,
                               size_t *out_written);

// Encode the placeholder map `{ "_placeholder": 0 }` used by empty-param
// FFI procs.
size_t cbor_size_map1_placeholder(void);
int cbor_encode_map1_placeholder(uint8_t *buf, size_t cap,
                                 size_t *out_written);

// Decode a top-level CBOR text string from `buf` (len bytes) into `out`
// (out_cap bytes, including space for a trailing NUL). On success, returns 0
// and stores the string length in *out_len (excluding the NUL); returns -1
// on malformed input or buffer overflow.
int cbor_decode_tstr(const uint8_t *buf, size_t len,
                     char *out, size_t out_cap, size_t *out_len);

// ── Map traversal helpers ───────────────────────────────────────────────────
//
// These are deliberately small and only handle the CBOR shapes our event
// payloads use today: tstr / bstr / uint / int / bool / nil / nested map.
// Anything more elaborate (tagged values, indefinite-length items, floats)
// is treated as an error.

// Open a CBOR map at *off. On success, returns 0, writes the entry count
// into *out_count, and advances *off past the map head.
int cbor_open_map(const uint8_t *buf, size_t len, size_t *off,
                  size_t *out_count);

// Decode a tstr at *off. On success, returns 0; *out_ptr / *out_len point
// to a borrowed view inside `buf` (no copy, no NUL). Advances *off past
// the value.
int cbor_borrow_tstr(const uint8_t *buf, size_t len, size_t *off,
                     const char **out_ptr, size_t *out_len);

// Decode a bstr at *off. Returns 0 on success; *out_ptr / *out_len point
// to a borrowed view inside `buf`. Advances *off past the value.
int cbor_borrow_bstr(const uint8_t *buf, size_t len, size_t *off,
                     const uint8_t **out_ptr, size_t *out_len);

// Skip over the CBOR value at *off, advancing *off past it. Recurses into
// arrays and maps. Returns 0 on success, -1 on malformed input or an
// unsupported value shape.
int cbor_skip_value(const uint8_t *buf, size_t len, size_t *off);

// Find the value paired with a given text key in the map that starts at
// *off (the map header is consumed by this call). On success, returns 0
// and sets *out_value_off to the offset of the value inside `buf`; on a
// missing key or malformed input, returns -1 (and *off is left at the end
// of the map so the caller can continue parsing the surrounding context).
int cbor_find_in_map(const uint8_t *buf, size_t len, size_t *off,
                     const char *key, size_t *out_value_off);

#endif // CBOR_HELPERS_H
