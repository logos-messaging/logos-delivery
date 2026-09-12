#include "json_utils.h"
#include <stdio.h>
#include <string.h>

const char* extract_json_field(const char *json, const char *field, char *buffer, size_t bufSize) {
    char searchStr[256];
    snprintf(searchStr, sizeof(searchStr), "\"%s\":\"", field);

    const char *start = strstr(json, searchStr);
    if (!start) {
        return NULL;
    }

    start += strlen(searchStr);
    const char *end = strchr(start, '"');
    if (!end) {
        return NULL;
    }

    size_t len = end - start;
    if (len >= bufSize) {
        len = bufSize - 1;
    }

    memcpy(buffer, start, len);
    buffer[len] = '\0';

    return buffer;
}

const char* extract_json_object(const char *json, const char *field, size_t *outLen) {
    char searchStr[256];
    snprintf(searchStr, sizeof(searchStr), "\"%s\":{", field);

    const char *start = strstr(json, searchStr);
    if (!start) {
        return NULL;
    }

    // Advance to the opening brace
    start = strchr(start, '{');
    if (!start) {
        return NULL;
    }

    // Find the matching closing brace (handles nested braces)
    int depth = 0;
    const char *p = start;
    while (*p) {
        if (*p == '{') depth++;
        else if (*p == '}') {
            depth--;
            if (depth == 0) {
                *outLen = (size_t)(p - start + 1);
                return start;
            }
        }
        p++;
    }
    return NULL;
}

static int base64_value(char c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}

int decode_json_base64_field(const char *json, const char *field, char *buffer, size_t bufSize) {
    char searchStr[256];
    snprintf(searchStr, sizeof(searchStr), "\"%s\":\"", field);

    const char *start = strstr(json, searchStr);
    if (!start || bufSize == 0) {
        return -1;
    }
    start += strlen(searchStr);
    const char *end = strchr(start, '"');
    if (!end) {
        return -1;
    }

    size_t pos = 0;
    size_t chars = 0; // base64 digits seen
    size_t pads = 0;  // '=' seen, only allowed at the end
    unsigned int acc = 0;
    int bits = 0;
    for (const char *p = start; p < end; p++) {
        if (*p == '=') {
            pads++;
            continue;
        }
        int v = base64_value(*p);
        if (v < 0 || pads > 0) {
            return -1; // not base64, or a digit after the padding
        }
        chars++;
        acc = (acc << 6) | (unsigned int)v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            if (pos >= bufSize - 1) {
                return -1;
            }
            buffer[pos++] = (char)((acc >> bits) & 0xFF);
        }
    }
    // A group of 4 digits gives 3 bytes; a final group of 2 or 3 digits is a
    // short one, a final group of 1 digit cannot be. Padding, when present,
    // must complete the final group exactly.
    size_t rem = chars % 4;
    if (rem == 1 || (pads != 0 && pads != (4 - rem) % 4)) {
        return -1;
    }
    buffer[pos] = '\0';
    return (int)pos;
}
