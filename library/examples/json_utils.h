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

// Decode a base64 JSON string field into buffer. The FFI renders the byte
// fields of a message (payload, meta, proof) as base64 strings.
// Returns the number of bytes decoded, or -1 when the field is missing, the
// base64 is invalid, or the output does not fit in bufSize - 1 bytes. The
// output is NUL-terminated so a text payload prints as a string.
int decode_json_base64_field(const char *json, const char *field, char *buffer, size_t bufSize);

#endif // JSON_UTILS_H
