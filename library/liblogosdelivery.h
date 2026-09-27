// Public C header for the Logos Messaging API (LMAPI) library.
//
// The call surface is generated from the {.ffi.} annotations in library/*.nim
// and written to generated/logosdelivery.h by `make liblogosdelivery`. That file
// is a build artifact, not checked in, so build the library before you compile
// against this header. This library builds on nim-ffi's poll model: every
// export submits a CBOR request and answers with a message read from
// logosdelivery_poll(); the generated header declares the message, the exports
// and the codecs, and a host brings its own loop (nim-ffi's host/ headers, or
// ffi/poll_host for a Nim host).
#pragma once
#ifndef __liblogosdelivery__
#define __liblogosdelivery__

#include <stddef.h>
#include <stdint.h>

#include "generated/logosdelivery.h"

// Kept as aliases of the generated NIMFFI_RET_* codes so existing callers that
// use the short names keep compiling. Guarded because the legacy libwaku header
// defines the same names with the same values.
#ifndef RET_OK
#define RET_OK NIMFFI_RET_OK
#endif
#ifndef RET_ERR
#define RET_ERR NIMFFI_RET_ERR
#endif
#ifndef RET_TIMEOUT
#define RET_TIMEOUT NIMFFI_RET_TIMEOUT
#endif

#endif /* __liblogosdelivery__ */
