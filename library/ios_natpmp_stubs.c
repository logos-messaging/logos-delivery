/**
 * iOS stub for getgateway.c functions.
 * iOS doesn't have net/route.h, so we provide a stub that returns failure.
 * NAT-PMP functionality won't work but the library will link.
 */

#include <stdint.h>
#include <netinet/in.h>

/* getdefaultgateway - returns -1 (failure) on iOS */
int getdefaultgateway(in_addr_t *addr) {
    (void)addr;  /* unused */
    return -1;   /* failure - not supported on iOS */
}
