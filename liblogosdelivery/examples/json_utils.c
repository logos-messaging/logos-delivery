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

int decode_json_byte_array(const char *json, const char *field, char *buffer, size_t bufSize) {
    char searchStr[256];
    snprintf(searchStr, sizeof(searchStr), "\"%s\":[", field);

    const char *start = strstr(json, searchStr);
    if (!start) {
        return -1;
    }

    // Advance to the opening bracket
    start = strchr(start, '[');
    if (!start) {
        return -1;
    }
    start++; // skip '['

    size_t pos = 0;
    const char *p = start;
    while (*p && *p != ']' && pos < bufSize - 1) {
        // Skip whitespace and commas
        while (*p == ' ' || *p == ',' || *p == '\n' || *p == '\r' || *p == '\t') p++;
        if (*p == ']') break;

        // Parse integer
        int val = 0;
        while (*p >= '0' && *p <= '9') {
            val = val * 10 + (*p - '0');
            p++;
        }
        buffer[pos++] = (char)val;
    }
    buffer[pos] = '\0';
    return (int)pos;
}
