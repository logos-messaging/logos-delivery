#!/bin/zsh
# Build the edge FFI wasm module. Two-step: nim compiles all .o (the -shared
# link it attempts fails — known issue), then we link a MAIN module with emcc.
set -e
cd "$(dirname "$0")/.."
source ~/emsdk/emsdk_env.sh >/dev/null 2>&1
SHIM=$PWD/library/edge/wasm_shims.h
QINC=$PWD/wasm-deps/shim-include
# The wasm-deps/{ffi,brokers} overrides are wired in config.nims under
# -d:emscripten -- they cannot be passed here, since config-file paths are
# registered after the command line and so take precedence over it.
nim c --cpu:wasm32 --os:linux --cc:clang --clang.exe:emcc --clang.linkerexe:emcc \
  --clang.cpp.exe:emcc --clang.cpp.linkerexe:emcc \
  -d:emscripten -d:disableMarchNative -d:release -d:useMalloc -d:noSignalHandler \
  --threads:off --mm:orc --debugger:off -d:chronicles_log_level=ERROR --hints:off --warnings:off \
  --passC:"-include $SHIM -I $QINC -Wno-error=incompatible-pointer-types -Wno-error=incompatible-function-pointer-types -Wno-error=int-conversion" \
  -o:build/wasm/edge_tmp.js library/edge/edge_lib.nim >/tmp/edgebuild.log 2>&1 || true
emcc nimcache/release/edge_lib/*.o -o build/wasm/edge.js \
  -O3 --no-entry -sEXIT_RUNTIME=0 -sMODULARIZE -sEXPORT_NAME=createEdgeModule -sASYNCIFY \
  -sALLOW_MEMORY_GROWTH -sSTACK_SIZE=16MB -sALLOW_TABLE_GROWTH \
  "-sEXPORTED_RUNTIME_METHODS=['ccall','addFunction','removeFunction','UTF8ToString','HEAPU8']" \
  "-sEXPORTED_FUNCTIONS=['_edge_new','_edge_lightpush_publish','_edge_filter_subscribe','_edge_store_query','_edge_store_connect','_edge_stop','_logosdeliveryedge_set_event_callback','_ffi_poll','_malloc','_free','_wsbridge_on_open','_wsbridge_on_message','_wsbridge_on_close','_wsbridge_on_error']" \
  -lm
echo "built build/wasm/edge.{js,wasm}"
