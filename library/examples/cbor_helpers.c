#include "cbor_helpers.h"

#include <string.h>

// dCBOR head: emit (major << 5) | argument for an unsigned argument, using
// the shortest valid encoding. Major 3 is text string, major 5 is map; for
// our use we pass argument = byte_count for text strings and argument =
// pair_count for maps.
static size_t cbor_head_size(uint64_t argument) {
    if (argument < 24)         return 1;
    if (argument < 0x100ULL)   return 2;
    if (argument < 0x10000ULL) return 3;
    if (argument < 0x100000000ULL) return 5;
    return 9;
}

static size_t cbor_head_emit(uint8_t *buf, size_t cap, size_t off,
                             uint8_t major, uint64_t argument) {
    const uint8_t mt = (uint8_t)(major << 5);
    if (argument < 24) {
        if (off + 1 > cap) return 0;
        buf[off] = (uint8_t)(mt | (uint8_t)argument);
        return off + 1;
    }
    if (argument < 0x100ULL) {
        if (off + 2 > cap) return 0;
        buf[off]     = (uint8_t)(mt | 24);
        buf[off + 1] = (uint8_t)argument;
        return off + 2;
    }
    if (argument < 0x10000ULL) {
        if (off + 3 > cap) return 0;
        buf[off]     = (uint8_t)(mt | 25);
        buf[off + 1] = (uint8_t)(argument >> 8);
        buf[off + 2] = (uint8_t)(argument);
        return off + 3;
    }
    if (argument < 0x100000000ULL) {
        if (off + 5 > cap) return 0;
        buf[off]     = (uint8_t)(mt | 26);
        buf[off + 1] = (uint8_t)(argument >> 24);
        buf[off + 2] = (uint8_t)(argument >> 16);
        buf[off + 3] = (uint8_t)(argument >> 8);
        buf[off + 4] = (uint8_t)(argument);
        return off + 5;
    }
    if (off + 9 > cap) return 0;
    buf[off]     = (uint8_t)(mt | 27);
    for (int i = 0; i < 8; i++) {
        buf[off + 1 + i] = (uint8_t)(argument >> (56 - 8 * i));
    }
    return off + 9;
}

static size_t cbor_tstr_size(size_t byte_len) {
    return cbor_head_size((uint64_t)byte_len) + byte_len;
}

static size_t cbor_tstr_emit(uint8_t *buf, size_t cap, size_t off,
                             const char *s, size_t byte_len) {
    const size_t after_head = cbor_head_emit(buf, cap, off, 3, (uint64_t)byte_len);
    if (after_head == 0) return 0;
    if (after_head + byte_len > cap) return 0;
    if (byte_len > 0) {
        memcpy(buf + after_head, s, byte_len);
    }
    return after_head + byte_len;
}

size_t cbor_size_map1_tstr_tstr(const char *key, const char *val) {
    if (key == NULL || val == NULL) return 0;
    const size_t klen = strlen(key);
    const size_t vlen = strlen(val);
    // map(1) head is always 1 byte for n < 24
    return 1 + cbor_tstr_size(klen) + cbor_tstr_size(vlen);
}

int cbor_encode_map1_tstr_tstr(uint8_t *buf, size_t cap,
                               const char *key, const char *val,
                               size_t *out_written) {
    if (buf == NULL || key == NULL || val == NULL || out_written == NULL) return -1;
    const size_t klen = strlen(key);
    const size_t vlen = strlen(val);
    size_t off = cbor_head_emit(buf, cap, 0, 5, 1); // map(1)
    if (off == 0) return -1;
    off = cbor_tstr_emit(buf, cap, off, key, klen);
    if (off == 0) return -1;
    off = cbor_tstr_emit(buf, cap, off, val, vlen);
    if (off == 0) return -1;
    *out_written = off;
    return 0;
}

size_t cbor_size_map1_placeholder(void) {
    // map(1) + tstr("_placeholder") + uint(0)
    return 1 + cbor_tstr_size(12) + 1;
}

int cbor_encode_map1_placeholder(uint8_t *buf, size_t cap, size_t *out_written) {
    if (buf == NULL || out_written == NULL) return -1;
    size_t off = cbor_head_emit(buf, cap, 0, 5, 1); // map(1)
    if (off == 0) return -1;
    off = cbor_tstr_emit(buf, cap, off, "_placeholder", 12);
    if (off == 0) return -1;
    // uint 0 (major 0, argument 0) → single byte 0x00
    if (off + 1 > cap) return -1;
    buf[off++] = 0x00;
    *out_written = off;
    return 0;
}

// Read a CBOR initial byte + argument. Returns number of bytes consumed
// (head only), or 0 on truncated input.
static size_t cbor_head_read(const uint8_t *buf, size_t len, size_t off,
                             uint8_t *out_major, uint64_t *out_arg) {
    if (off >= len) return 0;
    const uint8_t ib = buf[off];
    const uint8_t major = (uint8_t)(ib >> 5);
    const uint8_t ai    = (uint8_t)(ib & 0x1F);
    *out_major = major;
    if (ai < 24)       { *out_arg = ai; return 1; }
    if (ai == 24) {
        if (off + 2 > len) return 0;
        *out_arg = buf[off + 1];
        return 2;
    }
    if (ai == 25) {
        if (off + 3 > len) return 0;
        *out_arg = ((uint64_t)buf[off + 1] << 8) | (uint64_t)buf[off + 2];
        return 3;
    }
    if (ai == 26) {
        if (off + 5 > len) return 0;
        *out_arg = ((uint64_t)buf[off + 1] << 24) |
                   ((uint64_t)buf[off + 2] << 16) |
                   ((uint64_t)buf[off + 3] << 8)  |
                   (uint64_t)buf[off + 4];
        return 5;
    }
    if (ai == 27) {
        if (off + 9 > len) return 0;
        uint64_t v = 0;
        for (int i = 0; i < 8; i++) {
            v = (v << 8) | (uint64_t)buf[off + 1 + i];
        }
        *out_arg = v;
        return 9;
    }
    return 0; // 28..31 not used in our subset
}

int cbor_decode_tstr(const uint8_t *buf, size_t len,
                     char *out, size_t out_cap, size_t *out_len) {
    if (buf == NULL || out == NULL || out_len == NULL || out_cap == 0) return -1;
    uint8_t major = 0;
    uint64_t arg  = 0;
    const size_t head = cbor_head_read(buf, len, 0, &major, &arg);
    if (head == 0 || major != 3) return -1;
    if (head + arg > len) return -1;
    if (arg + 1 > (uint64_t)out_cap) return -1; // need room for NUL
    if (arg > 0) memcpy(out, buf + head, (size_t)arg);
    out[arg] = '\0';
    *out_len = (size_t)arg;
    return 0;
}

int cbor_open_map(const uint8_t *buf, size_t len, size_t *off,
                  size_t *out_count) {
    if (buf == NULL || off == NULL || out_count == NULL) return -1;
    uint8_t major = 0;
    uint64_t arg  = 0;
    const size_t head = cbor_head_read(buf, len, *off, &major, &arg);
    if (head == 0 || major != 5) return -1;
    *off += head;
    *out_count = (size_t)arg;
    return 0;
}

// Internal: borrow a tstr/bstr (major 2 or 3) at *off. `expect_major` lets
// the two public helpers share the byte-string body.
static int cbor_borrow_string(const uint8_t *buf, size_t len, size_t *off,
                              uint8_t expect_major,
                              const uint8_t **out_ptr, size_t *out_len) {
    uint8_t major = 0;
    uint64_t arg  = 0;
    const size_t head = cbor_head_read(buf, len, *off, &major, &arg);
    if (head == 0 || major != expect_major) return -1;
    if (*off + head + arg > len) return -1;
    *out_ptr = buf + *off + head;
    *out_len = (size_t)arg;
    *off += head + (size_t)arg;
    return 0;
}

int cbor_borrow_tstr(const uint8_t *buf, size_t len, size_t *off,
                     const char **out_ptr, size_t *out_len) {
    if (out_ptr == NULL) return -1;
    const uint8_t *p = NULL;
    const int r = cbor_borrow_string(buf, len, off, 3, &p, out_len);
    if (r != 0) return r;
    *out_ptr = (const char *)p;
    return 0;
}

int cbor_borrow_bstr(const uint8_t *buf, size_t len, size_t *off,
                     const uint8_t **out_ptr, size_t *out_len) {
    return cbor_borrow_string(buf, len, off, 2, out_ptr, out_len);
}

int cbor_skip_value(const uint8_t *buf, size_t len, size_t *off) {
    if (buf == NULL || off == NULL || *off >= len) return -1;
    uint8_t major = 0;
    uint64_t arg  = 0;
    const size_t head = cbor_head_read(buf, len, *off, &major, &arg);
    if (head == 0) return -1;
    *off += head;
    switch (major) {
        case 0: case 1:
            // uint / negative int — argument is the whole value
            return 0;
        case 2: case 3:
            // bstr / tstr — argument bytes follow the head
            if (*off + arg > len) return -1;
            *off += (size_t)arg;
            return 0;
        case 4: {
            // array — `arg` items follow
            for (uint64_t i = 0; i < arg; i++) {
                if (cbor_skip_value(buf, len, off) != 0) return -1;
            }
            return 0;
        }
        case 5: {
            // map — `arg` key/value pairs follow
            for (uint64_t i = 0; i < arg; i++) {
                if (cbor_skip_value(buf, len, off) != 0) return -1; // key
                if (cbor_skip_value(buf, len, off) != 0) return -1; // value
            }
            return 0;
        }
        case 6:
            // tag — skip and recurse into the tagged value
            return cbor_skip_value(buf, len, off);
        case 7: {
            // simple/float: only the small set we expect is handled
            const uint8_t ib = buf[*off - head]; // re-read the initial byte
            const uint8_t ai = (uint8_t)(ib & 0x1F);
            switch (ai) {
                case 20: case 21: case 22: case 23: // false / true / null / undef
                    return 0;
                case 25: // float16 — not used, but cheap to skip
                    if (*off + 2 > len) return -1;
                    *off += 2; return 0;
                case 26: // float32
                    if (*off + 4 > len) return -1;
                    *off += 4; return 0;
                case 27: // float64
                    if (*off + 8 > len) return -1;
                    *off += 8; return 0;
                default:
                    return -1;
            }
        }
        default:
            return -1;
    }
}

int cbor_find_in_map(const uint8_t *buf, size_t len, size_t *off,
                     const char *key, size_t *out_value_off) {
    if (buf == NULL || off == NULL || key == NULL || out_value_off == NULL)
        return -1;
    size_t count = 0;
    if (cbor_open_map(buf, len, off, &count) != 0) return -1;
    const size_t key_len = strlen(key);
    int found = 0;
    for (size_t i = 0; i < count; i++) {
        const char *k_ptr = NULL;
        size_t k_len = 0;
        if (cbor_borrow_tstr(buf, len, off, &k_ptr, &k_len) != 0) return -1;
        if (!found && k_len == key_len && memcmp(k_ptr, key, k_len) == 0) {
            *out_value_off = *off;
            found = 1;
        }
        // Still need to advance past the value (whether matched or not) so
        // the surrounding caller sees a clean end-of-map cursor.
        if (cbor_skip_value(buf, len, off) != 0) return -1;
    }
    return found ? 0 : -1;
}
