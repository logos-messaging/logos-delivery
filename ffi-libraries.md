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

## Problems

> [!CAUTION] 
> 
> ### Stability promise
> 
> The split was meant to prevent misuse of protocols. But I believe it doesn't:
> 
> - Linking another `.so` is one build-file line — nothing fails.
> - Both libraries ship from the same repo at the same cadence; neither artifact carries a "use at your own risk" signal.
> - "Stable" vs "may change" is a claim made in docs and headers, not in the `.so` boundary.
>
> **Headers, naming, and docs are what communicate the tier.**

1. **Status needs Store, Messaging API excludes it** \
    The split forces a false choice: pollute the Messaging API with Store (compromises minimalism), or push Status to `libwaku` (defeats the "one library for messaging consumers" promise).
2. **Two libraries means two nodes** \
   Each FFI library creates its own `Waku` instance via `Waku.new(...)`. A consumer that wanted *both* the Messaging API and a kernel call (e.g. Store) couldn't just link both `.so`s — they'd be running two independent libp2p stacks.
3. **Duplicated plumbing** \
    Both libraries implement: FFI context, JSON config parsing, lifecycle, etc.
4. **`createNode` implementations diverge** \
    NOTE: This is purely an AI-detected issue. \
    `liblogosdelivery` parses JSON case-insensitively and rejects unknown fields; `libwaku` doesn't. `libwaku` also strips `restServerConf` after parsing; `liblogosdelivery` keeps it. 

## Proposal

1. **Merge into one library** \
   Keep [`liblogosdelivery`](liblogosdelivery/) as the host, retire `library/libwaku`.

2. **Tiered surface inside the library** \
   Library exposes:
   - Reliable Channels API
   - Messaging API
   - Kernel API

   Reliable Channels API and Messaging API are the supported, stable surface. Kernel API is the advanced surface, explicitly marked as "use at your own risk, subject to change at any moment".

   Tiering is expressed via separate C headers, not a separate library and not a longer symbol prefix.

3. (maybe) **Control what reaches Logos Core** \
   Not every symbol has to be exposed in the Logos Core module API — that's a second layer of filtering we keep at the module boundary.

### Splitting the C header

| Header | Tier | Stability promise |
|-|-|-|
| `liblogosdelivery.h` | Messaging API<br>Reliable Channel API | Stable, supported |
| `liblogosdelivery_kernel.h` | Kernel / advanced | "Use at your own risk", may change |

The "advanced / unsupported" signal comes from `#include "liblogosdelivery_kernel.h"` — the consumer opts in deliberately. Symbol names stay short: `logosdelivery_store_query(...)` instead of `logosdelivery_kernel_store_query(...)`.

### Object-oriented accessor

With a "single node" requirement, we might end up with these node methods next to each other, exposing Kernel API next to the Messaging API, instead of hiding it.

```nim
# Object with methods. Pseudocode.
Node {
    proc send(...)
    proc subscribe(...)
    proc relay(...): Relay
    proc lightpush(...): LightPush
    proc store(...): Store
}
```

To actually hide it, I think we should group the kernel API under an object-oriented accessor like this:

```nim
# Object with methods. Pseudocode.
Node {
    proc send(...)
    proc subscribe(...)
    proc kernel(): Kernel
}

Kernel {
    proc relay(...): Relay
    proc lightpush(...): LightPush
    proc store(): Store
}
```

Then the usage looks something like this:

```nim
node = createNode("logos.dev", Core)

# Access Messaging API
node.send(...)

# Access Kernel API
node.kernel().store().query(...)
```

### Naming

I'm not sure if "kernel" is the right word. In reality, "Kernel API" is not an API, it's a group of protocol APIs (relay, lightpush, store, etc). So maybe we should call it just `protocols`?

Applying this to the example above, it would look like this:

```nim
node.protocols().store().query(...)
```

The same could be applied to file naming: `liblogosdelivery_kernel.h` → `liblogosdelivery_protocols.h`.

## Suggested code changes

1. **Decide kernel naming:** `kernel` vs `protocols` \
    Locks in the C header filename, the Nim accessor (`node.kernel()` / `node.protocols()`), and the symbol grouping in docs. Everything below assumes `kernel` as a placeholder.
2. **Split [`liblogosdelivery.h`](liblogosdelivery/liblogosdelivery.h) into two headers** \
    Keep the existing one as the Messaging + Reliable Channel API surface. Add `liblogosdelivery_kernel.h` for the advanced surface. Both pull symbols from the same `.so`. Hand-authored — Nim's `exportc` doesn't auto-split.
3. **Move kernel calls inside `liblogosdelivery`** \
    Bring every per-protocol call from [`library/kernel_api/`](library/kernel_api/) (discovery, ping, debug, relay, store, lightpush, filter) under `liblogosdelivery/`
4. **Add the Nim object-oriented accessor** \
    Group per-protocol calls under a `Kernel` object reachable via `node.kernel()`. Messaging-API methods (`send`, `subscribe`, …) stay on `Node` directly.
5. **Unify `createNode` and JSON parsing** \
    Pick the `liblogosdelivery` semantics (case-insensitive, reject-unknown). Resolve the `restServerConf` divergence — strip it for FFI, keep it for CLI.
6. **Unify lifecycle plumbing** 
    One `FFIContext`, one set of `start_node` / `stop_node` / `destroy`. Shared between both headers.
7.  **Remove `library/libwaku`** once nothing references it.
