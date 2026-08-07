// liblogosdelivery_kernel.h — compatibility alias for liblogosdelivery.h.
//
// This header used to declare the low-level `waku_*` kernel API separately from
// the stable messaging surface, so that including it was a deliberate opt-in.
// That split no longer exists: the call surface is generated as one header, and
// liblogosdelivery.h declares every entry point. This file is kept only so
// existing includes keep resolving.
//
// The tiering still holds as a support promise, even though the compiler no
// longer enforces it. The `waku_*` functions expose per-protocol internals
// (relay, filter, lightpush, store, discovery, peer management) and may change
// or be removed at ANY time, without notice or a deprecation cycle. Only the
// messaging and reliable-channel entry points are
// supported.
//
// See https://github.com/logos-messaging/logos-delivery/issues/3851 for the
// tiering rationale.
#pragma once
#ifndef __liblogosdelivery_kernel__
#define __liblogosdelivery_kernel__

#include "liblogosdelivery.h"

#endif /* __liblogosdelivery_kernel__ */
