/* Force-included (via --passC:-include) for wasm/emscripten builds.
 * Declares POSIX-ish symbols the Nim stdlib / deps reference under --os:linux
 * but that emscripten's headers don't provide. Definitions live in
 * wasm_shims.nim's {.emit.} block. */
#ifndef LD_WASM_SHIMS_H
#define LD_WASM_SHIMS_H

/* Force-included into every compile unit, including .S assembly — so guard the
 * C declarations from the assembler. */
#ifndef __ASSEMBLER__

/* Nim's system/threadids.nim (linux, non-amd64) calls syscall(__NR_gettid).
 * emscripten declares neither. The process is single-threaded in wasm, so a
 * constant thread id is fine. */
long syscall(long number, ...);
extern long __NR_gettid;

#endif /* __ASSEMBLER__ */
#endif
