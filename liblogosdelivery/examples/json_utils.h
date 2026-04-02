#ifndef JSON_UTILS_H
#define JSON_UTILS_H

#include <stddef.h>

// Extract a JSON string field value into buffer.
// Returns pointer to buffer on success, NULL on failure.
// Very basic parser - for production use a proper JSON library.
const char* extract_json_field(const char *json, const char *field, char *buffer, size_t bufSize);

// Extract a nested JSON object as a raw string.
// Returns a pointer into `json` at the start of the object, and sets `outLen`.
// Handles nested braces.
const char* extract_json_object(const char *json, const char *field, size_t *outLen);

// Decode a JSON array of integers (byte values) into a buffer.
// Parses e.g. [72,101,108,108,111] into "Hello".
// Returns number of bytes decoded, or -1 on error.
int decode_json_byte_array(const char *json, const char *field, char *buffer, size_t bufSize);

#endif // JSON_UTILS_H
