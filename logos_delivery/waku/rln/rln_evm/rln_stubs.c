// Link-time stand-ins for zerokit's RLN FFI, compiled instead of librln when
// the build defines `disable_rln`. The Nim side declares these with `importc`
// and no `dynlib`, so they must resolve at link time even where RLN is unused.
//
// Generated from the `importc` names in rln_interface.nim.

#include <stdio.h>
#include <stdlib.h>

static void logosdelivery_rln_disabled(const char *symbol) {
  fprintf(stderr,
          "liblogosdelivery: %s called, but this build has -d:disable_rln and "
          "no RLN implementation.\n",
          symbol);
  abort();
}

void ffi_bytes_le_to_cfr(void) { logosdelivery_rln_disabled("ffi_bytes_le_to_cfr"); }
void ffi_bytes_le_to_rln_partial_proof(void) { logosdelivery_rln_disabled("ffi_bytes_le_to_rln_partial_proof"); }
void ffi_bytes_le_to_rln_proof(void) { logosdelivery_rln_disabled("ffi_bytes_le_to_rln_proof"); }
void ffi_c_string_free(void) { logosdelivery_rln_disabled("ffi_c_string_free"); }
void ffi_cfr_free(void) { logosdelivery_rln_disabled("ffi_cfr_free"); }
void ffi_cfr_to_bytes_le(void) { logosdelivery_rln_disabled("ffi_cfr_to_bytes_le"); }
void ffi_cfr_zero(void) { logosdelivery_rln_disabled("ffi_cfr_zero"); }
void ffi_compute_id_secret(void) { logosdelivery_rln_disabled("ffi_compute_id_secret"); }
void ffi_extended_key_gen(void) { logosdelivery_rln_disabled("ffi_extended_key_gen"); }
void ffi_finish_rln_proof(void) { logosdelivery_rln_disabled("ffi_finish_rln_proof"); }
void ffi_generate_partial_zk_proof(void) { logosdelivery_rln_disabled("ffi_generate_partial_zk_proof"); }
void ffi_generate_rln_proof(void) { logosdelivery_rln_disabled("ffi_generate_rln_proof"); }
void ffi_hash_to_field_le(void) { logosdelivery_rln_disabled("ffi_hash_to_field_le"); }
void ffi_poseidon_hash_pair(void) { logosdelivery_rln_disabled("ffi_poseidon_hash_pair"); }
void ffi_rln_free(void) { logosdelivery_rln_disabled("ffi_rln_free"); }
void ffi_rln_new(void) { logosdelivery_rln_disabled("ffi_rln_new"); }
void ffi_rln_new_with_params(void) { logosdelivery_rln_disabled("ffi_rln_new_with_params"); }
void ffi_rln_partial_proof_free(void) { logosdelivery_rln_disabled("ffi_rln_partial_proof_free"); }
void ffi_rln_partial_proof_to_bytes_le(void) { logosdelivery_rln_disabled("ffi_rln_partial_proof_to_bytes_le"); }
void ffi_rln_partial_witness_input_free(void) { logosdelivery_rln_disabled("ffi_rln_partial_witness_input_free"); }
void ffi_rln_partial_witness_input_new(void) { logosdelivery_rln_disabled("ffi_rln_partial_witness_input_new"); }
void ffi_rln_proof_free(void) { logosdelivery_rln_disabled("ffi_rln_proof_free"); }
void ffi_rln_proof_get_values(void) { logosdelivery_rln_disabled("ffi_rln_proof_get_values"); }
void ffi_rln_proof_new(void) { logosdelivery_rln_disabled("ffi_rln_proof_new"); }
void ffi_rln_proof_to_bytes_le(void) { logosdelivery_rln_disabled("ffi_rln_proof_to_bytes_le"); }
void ffi_rln_proof_values_free(void) { logosdelivery_rln_disabled("ffi_rln_proof_values_free"); }
void ffi_rln_proof_values_get_external_nullifier(void) { logosdelivery_rln_disabled("ffi_rln_proof_values_get_external_nullifier"); }
void ffi_rln_proof_values_get_nullifier(void) { logosdelivery_rln_disabled("ffi_rln_proof_values_get_nullifier"); }
void ffi_rln_proof_values_get_root(void) { logosdelivery_rln_disabled("ffi_rln_proof_values_get_root"); }
void ffi_rln_proof_values_get_x(void) { logosdelivery_rln_disabled("ffi_rln_proof_values_get_x"); }
void ffi_rln_proof_values_get_y(void) { logosdelivery_rln_disabled("ffi_rln_proof_values_get_y"); }
void ffi_rln_witness_input_free(void) { logosdelivery_rln_disabled("ffi_rln_witness_input_free"); }
void ffi_rln_witness_input_new(void) { logosdelivery_rln_disabled("ffi_rln_witness_input_new"); }
void ffi_seeded_extended_key_gen(void) { logosdelivery_rln_disabled("ffi_seeded_extended_key_gen"); }
void ffi_vec_cfr_free(void) { logosdelivery_rln_disabled("ffi_vec_cfr_free"); }
void ffi_vec_cfr_get(void) { logosdelivery_rln_disabled("ffi_vec_cfr_get"); }
void ffi_vec_cfr_len(void) { logosdelivery_rln_disabled("ffi_vec_cfr_len"); }
void ffi_vec_cfr_new(void) { logosdelivery_rln_disabled("ffi_vec_cfr_new"); }
void ffi_vec_cfr_push(void) { logosdelivery_rln_disabled("ffi_vec_cfr_push"); }
void ffi_vec_u8_free(void) { logosdelivery_rln_disabled("ffi_vec_u8_free"); }
void ffi_verify_with_roots(void) { logosdelivery_rln_disabled("ffi_verify_with_roots"); }
