#include "../liblogosdelivery.h"
#include <stdio.h>
#include <string.h>

static int verifier_invoked = 0;

static int test_verifier_cb(
    const char *proof_hex,
    const char *canonical_hex,
    const char *requester_peer_id,
    char *out_desc,
    size_t out_desc_len,
    void *user_data) {
  (void)canonical_hex;
  (void)requester_peer_id;
  (void)out_desc;
  (void)out_desc_len;
  (void)user_data;
  verifier_invoked++;
  if (proof_hex != NULL) {
    return -1;
  }
  return 0;
}

int main(void) {
  int rc;

  rc = logosdelivery_set_eligibility_verifier(NULL, test_verifier_cb, NULL);
  if (rc != RET_ERR) {
    fprintf(stderr, "expected RET_ERR for NULL ctx, got %d\n", rc);
    return 1;
  }

  rc = logosdelivery_set_eligibility_provider(NULL, NULL, NULL);
  if (rc != RET_ERR) {
    fprintf(stderr, "expected RET_ERR for NULL ctx on provider clear, got %d\n", rc);
    return 1;
  }

  printf("eligibility ABI smoke: registration entry points linked OK\n");
  return 0;
}
