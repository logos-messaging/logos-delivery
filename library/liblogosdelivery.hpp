// Public C++ header for the Logos Messaging API (LMAPI) library.
//
// The C++ binding is generated from the {.ffi.} annotations in library/*.nim
// and written to generated/logosdelivery.hpp by `make liblogosdelivery`, next to
// the C one. It is a build artifact, not checked in, so build the library before
// you compile against this header.
//
// `LogosDeliveryCtx` owns one node: `create(configJson)` makes it and its
// destructor destroys it. Every call has a blocking form and an `*Async` one
// returning a std::future, both yielding a `Result<T>`. The external service
// discovery host registers its reverse-call implementations with
// `setSd<Verb>Impl` and answers through the call token it is handed, from any
// thread.
//
// Self-contained: do not include liblogosdelivery.h (or the kernel header, which
// includes it) in the same translation unit -- its C `LogosDeliveryCtx` struct
// collides with the class. The kernel calls are methods of the class.
#pragma once

#include "generated/logosdelivery.hpp"
