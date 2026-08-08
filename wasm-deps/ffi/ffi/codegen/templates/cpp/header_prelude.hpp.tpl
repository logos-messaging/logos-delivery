#pragma once
// Generated bindings require C++20 (designated initializers and other
// C++20 constructs are used throughout the emitted code).
// MSVC keeps __cplusplus at 199711L unless /Zc:__cplusplus is passed,
// so consult _MSVC_LANG when present (it always reflects the active
// /std:c++XX level).
#if defined(_MSVC_LANG)
#  if _MSVC_LANG < 202002L
#    error "nim-ffi generated headers require C++20 or later (use /std:c++20)"
#  endif
#elif !defined(__cplusplus) || __cplusplus < 202002L
#  error "nim-ffi generated headers require C++20 or later"
#endif
#include <string>
#include <cstdint>
#include <chrono>
#include <charconv>
#include <mutex>
#include <condition_variable>
#include <memory>
#include <functional>
#include <future>
#include <vector>
#include <optional>
#include <type_traits>
#include <cstring>
#include <cassert>
extern "C" {
#include <tinycbor/cbor.h>
}

// nim-ffi result-callback status codes (mirror ffi/ffi_types.nim and the C
// header). Guarded so a translation unit that also pulls in the C header keeps
// a single definition.
#ifndef NIMFFI_RET_OK
#define NIMFFI_RET_OK 0
#define NIMFFI_RET_ERR 1
#define NIMFFI_RET_MISSING_CALLBACK 2
#define NIMFFI_RET_STALE_WARN 3
#endif
