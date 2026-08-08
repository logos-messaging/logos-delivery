## Compile-time selection of the execution transport.
##
## Default (threaded): each FFIContext owns an FFI worker thread and an event
## thread, woken over chronos ThreadSignalPtr with requests carried on a queue
## bank. Those need OS threads and eventfd-style signalling, neither of which
## exists in a baseline WebAssembly sandbox.
##
## `singleThreaded` collapses the workers onto the calling thread: a request is
## spawned on the caller's chronos loop and driven by the host through
## `ffi_poll()`. Auto-selected for Emscripten/WASM; forceable anywhere with
## `-d:ffiSingleThreaded`.
const singleThreaded* = defined(ffiSingleThreaded) or defined(emscripten)
