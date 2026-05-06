# FFI library consolidation

We have two C FFI libraries built from the same source tree:

- [`liblogosdelivery`](liblogosdelivery/) — high-level Messaging API.
- [`library/libwaku`](library/) — low-level kernel API (per-protocol).

This doc proposes merging them into one library with a tiered surface, and uses that to answer the open Store-access question on the 2026 GA roadmap.

## Discussions

- https://github.com/logos-messaging/logos-delivery/pull/3714#discussion_r2773830458 — original split rationale, plus naming side-point.
- https://roadmap.logos.co/messaging/roadmap/milestones/2026-messaging-api-general-availability — Store access for Status.

## Context

The split was deliberate ([thread above](https://github.com/logos-messaging/logos-delivery/pull/3714#discussion_r2773830458)):

> The aim is to avoid any further messaging consumers to use `libwaku` (kernel API) so that they are not tempted to use it.

> We do not want to promise anything about KernelAPI outward, that is open for change. So we would like to lead out libwaku slowly and let Status/Chat/anybody only depend on this new API layer.

Counter-position from the same thread (Igor):

> Why does it have to be a separate library? I thought we want to just add the API into existing `libwaku`. Then it would be up to the users which API to use — low- or high-level.

With the [plan](https://roadmap.logos.co/messaging/roadmap/milestones/2026-status-logos-delivery-integration) of using Messaging API in Status, we are ought to expose Store API from the same node, because Status needs Store for offline history, community descriptions, profiles, missed messages. Store was intentionally excluded from the Messaging API, so the intuitive solution is to expose Store next to it. This is mentioned in [Messagin API GA milestone](https://roadmap.logos.co/messaging/roadmap/milestones/2026-messaging-api-general-availability).

## Requirements

- Messaging API consumers (e.g. Status) can access Store API from the same node they created using Messaging API.
- The default surface stays minimal — Messaging API is the front door for developers.

## Principles

1. **One library.** Two FFI plumbings duplicated across `createNode`, lifecycle, FFI context, JSON parsing is maintenance debt with no upside.
2. **Tiered surface inside the library.** Messaging API is the supported, recommended, stable surface. Kernel calls are the advanced surface — usable when explicitly needed (Store for Status; per-protocol calls for advanced tooling), not the default. Tiering is expressed via separate C headers, not a separate library and not a longer symbol prefix (see [Proposal](#proposal)).
3. **"Don't promise stability" is a documentation concern, not a separate-library concern.** A consumer that wants the kernel API just adds another link line today — the split doesn't actually prevent misuse. Headers, naming, and docs do.
4. **We MAY control what we expose to Logos Core**. Not all library functions have to be exposed to Logos Core module API, and this is also where we could control what users have access to.

## Problems

1. **Status needs Store, Messaging API excludes it** \
    The split forces a false choice: pollute the Messaging API with Store (compromises minimalism), or push Status to `libwaku` (defeats the "one library for messaging consumers" promise).
1. **Two libraries means two nodes** \
   Each FFI library creates its own `Waku` instance via `Waku.new(...)`. A consumer that wanted *both* the Messaging API and a kernel call (e.g. Store) couldn't just link both `.so`s — they'd be running two independent libp2p stacks.
2. **Duplicated plumbing** \
    Both libraries implement: FFI context, JSON config parsing, lifecycle, etc.

## 

## Proposal

Merge into a single library — keep [`liblogosdelivery`](liblogosdelivery/) as the host, retire `library/libwaku`.

Answering

All symbols share the same `logosdelivery_` prefix. Tiering is expressed by splitting the C header:

| Header | Tier | Audience | Stability promise |
|-|-|-|-|
| `liblogosdelivery.h` | Messaging API | Default — app developers, Logos Core | Stable, supported |
| `liblogosdelivery_kernel.h` | Kernel / advanced | Status (Store), advanced tooling | "Use at your own risk", may change |

Both headers expose symbols from the same `.so`, so they share node lifecycle, FFI context, JSON config parsing — no duplication, single `Waku` instance.

This is a common C pattern (SDL, OpenSSL, POSIX). The "advanced / unsupported" signal comes from `#include "liblogosdelivery_kernel.h"` — the consumer makes a deliberate choice to opt in. Symbol names stay short: `logosdelivery_store_query(...)` instead of `logosdelivery_kernel_store_query(...)`.

This answers the 2026 GA roadmap's open question: **low-level access lives in the same library, behind a separate header**. Status `#include`s `liblogosdelivery_kernel.h`, calls `logosdelivery_store_query(...)`, and shares the existing node.

### Naming side-note

Filipe's point in #3714: drop "waku" from public surfaces, keep it for internals / unsupported things. The merged library is a natural moment to apply this — pick a final public prefix (`logosdelivery_`, `lm_`, …) and stick with it. Open.

## Code changes

1. **Split [`liblogosdelivery.h`](liblogosdelivery/liblogosdelivery.h) into two headers.** Keep the existing one as the Messaging API surface. Add `liblogosdelivery_kernel.h` for the advanced surface. Both pull symbols from the same `.so`. Hand-authored — Nim's `exportc` doesn't auto-split.
2. **Move kernel calls inside `liblogosdelivery`.** Bring every per-protocol call from [`library/kernel_api/`](library/kernel_api/) (peer manager, discovery, ping, debug, relay, store, lightpush, filter) under `liblogosdelivery/`. All keep the `logosdelivery_` prefix; declarations land in `liblogosdelivery_kernel.h`.
3. **Add Store access** under the kernel header. Required by Status for the 2026 GA milestone.
4. **Unify `createNode` and JSON parsing.** Pick the `liblogosdelivery` semantics (case-insensitive, reject-unknown). Resolve the `restServerConf` divergence — strip it for FFI, keep it for CLI.
5. **Unify lifecycle plumbing.** One `FFIContext`, one set of `start_node` / `stop_node` / `destroy`. Shared between both headers.
6. **Migrate `libwaku` consumers** one by one. Each moves to the merged library; their kernel calls map to the new declarations in `liblogosdelivery_kernel.h`.
7. **Remove `library/libwaku`** once nothing references it. Non-breaking by sequencing.

<details>
<summary>Surface comparison</summary>

`liblogosdelivery` (high-level, today):
- `logosdelivery_create_node` / `start_node` / `stop_node` / `destroy`
- `logosdelivery_subscribe` / `unsubscribe`
- `logosdelivery_send` — returns `requestId`
- `logosdelivery_set_event_callback` — events: `message_sent`, `message_propagated`, `message_received`, `message_error`, `connection_status_change`
- `logosdelivery_get_available_node_info_ids` / `get_node_info` / `get_available_configs`

`library/libwaku` (low-level, today):
- `waku_new` / `waku_destroy`
- per-protocol modules included from [`libwaku.nim:19-28`](library/libwaku.nim#L19-L28): `peer_manager_api`, `discovery_api`, `node_lifecycle_api`, `debug_node_api`, `ping_api`, `relay_api`, `store_api`, `lightpush_api`, `filter_api`.

</details>
