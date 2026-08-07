## Compile-time selection of the execution transport.
##
## Default (threaded): each FFIContext spawns an FFI worker thread + a watchdog
## thread and hands requests over a chronos ThreadSignalPtr + SPSC channel.
## Those rely on OS threads + eventfd-style signalling, absent in a baseline
## WebAssembly sandbox.
##
## `singleThreaded` collapses the worker onto the calling thread: a request runs
## inline to completion. Auto-selected for Emscripten/WASM; forceable anywhere
## with `-d:ffiSingleThreaded`.
const singleThreaded* = defined(ffiSingleThreaded) or defined(emscripten)
