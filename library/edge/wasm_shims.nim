## wasm/emscripten portability shims. Import early in a wasm build so the C
## definitions are linked. Declarations live in wasm_shims.h (force-included via
## --passC:-include). See that header for rationale.
##
## Only active for emscripten; a no-op elsewhere.

when defined(emscripten):
  {.emit: """
#include <stdio.h>
long __NR_gettid = 178;
long syscall(long number, ...) { return 1; }
/* Unbuffer stdout/stderr so logs flush immediately (wasm block-buffers them,
   which otherwise truncates output when the host process exits). */
__attribute__((constructor)) static void wasm_unbuffer_stdio(void) {
  setvbuf(stdout, NULL, _IONBF, 0);
  setvbuf(stderr, NULL, _IONBF, 0);
}
""".}
