/**
 * iOS stubs for BearSSL tools functions not normally included in the library.
 * These are typically from the BearSSL tools/ directory which is for CLI tools.
 */

#include <stddef.h>

/* x509_noanchor context - simplified stub */
typedef struct {
    void *vtable;
    void *inner;
} x509_noanchor_context;

/* Stub for x509_noanchor_init - used to skip anchor validation */
void x509_noanchor_init(x509_noanchor_context *xwc, const void **inner) {
    if (xwc && inner) {
        xwc->inner = (void*)*inner;
        xwc->vtable = NULL;
    }
}

/* TAs (Trust Anchors) - empty array stub */
/* This is typically defined by applications with their CA certificates */
typedef struct {
    void *dn;
    size_t dn_len;
    unsigned flags;
    void *pkey;
} br_x509_trust_anchor;

const br_x509_trust_anchor TAs[1] = {{0}};
const size_t TAs_NUM = 0;
