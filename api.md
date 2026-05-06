# API design and consistency

We have a few interfaces to configure a Delivery node: CLI, library (Nim / C-bindings), REST. We should agree which is for which role, and what each looks like.

## Discussions

- https://github.com/logos-messaging/logos-delivery/issues/3795
- https://github.com/logos-messaging/logos-delivery/pull/3828
  - https://github.com/logos-messaging/logos-delivery/pull/3828#issuecomment-4317261531
  - https://github.com/logos-messaging/logos-delivery/pull/3828#issuecomment-4337495581
  - https://github.com/logos-messaging/logos-delivery/pull/3828#issuecomment-4353802313
- https://github.com/logos-co/logos-delivery-module/issues/18

## Roles

- **App developer** — sends/receives messages on a known network.
- **Node operator** — runs a fleet node 24/7.
- **Tester (DST / QA)** — drives custom configs, often many nodes per host.

## Requirements

- **No breaking changes.** Soft deprecations are fine.
- **Good defaults.** App developers should get a working node from a one-liner.
- **Flexibility for node operators.** Every preset/mode-controlled value must be overridable by an explicit field (#3795).

## Principles

1. Every node starts from a `WakuNodeConf`. Every interface must produce one deterministically:

   ```mermaid
   flowchart LR
       CLI["CLI flags<br/>--preset, --tcp-port, --relay, ..."] -->|build| Conf
       Msg["Library: Messaging API<br/>preset, mode, overrides"] -->|build| Conf
       Full["Library: <br/>full WakuNodeConf"] -->|pass| Conf
       Conf[WakuNodeConf] --> Waku["Waku.new(conf)"]
   ```
2. Different interfaces don't need identical argument lists. Each is shaped for its role.
3. Developer gets a shortcut: `(preset, mode, overrides?)`. They never assemble a full `WakuNodeConf`.
4. Operator gets the full `WakuNodeConf` surface.

## Problems

1. **No `(preset, mode)` entry point.** The library only has `createNode(conf: WakuNodeConf)`:
    https://github.com/logos-messaging/logos-delivery/blob/75864a705ea0b913d517a5f3640747f8709e9e53/waku/api/api.nim#L16
    and the C FFI mirror at:
    https://github.com/logos-messaging/logos-delivery/blob/75864a705ea0b913d517a5f3640747f8709e9e53/liblogosdelivery/logos_delivery_api/node_api.nim#L94-L96
    The Messaging API shape doesn't exist.
2. **`logosdelivery_create_node(configJson)` mixes Messaging-API and full-CLI fields in the same blob.** A caller can pass `"preset": "twn"` next to any of ~80 `WakuNodeConf` fields.
3. **`--preset` overrides aren't uniform.** Some preset-controlled fields silently win, some warn, some get overridden. Behaviour differs per field.
4. **Cluster-id implicitly selects a preset.** [`cli_args.nim:926-935`](tools/confutils/cli_args.nim#L926-L935) infers presets from `--cluster-id=1` / `--cluster-id=2` and only warns. Implicit and confusing.

> See also [`ffi-libraries.md`](ffi-libraries.md) for the separate question of consolidating the two C FFI libraries.

## Proposal

### Library

Two entry points, both produce a `WakuNodeConf` and call the same `Waku.new(...)`:

| Entry point | Audience |
|-|-|
| `createNode(preset, mode, overrides?)` | Developer (Messaging API) |
| `createNode(conf: WakuNodeConf)` | Tester, advanced tooling |

### CLI

Full `WakuNodeConf` surface. `--preset` is a shortcut for network-level params; explicit flags override.

**`--mode` should be removed.** Today it is purely a protocol-toggle shortcut ([`cli_args.nim:1126-1144`](tools/confutils/cli_args.nim#L1126-L1144)) — six `withRelay` / `withLightPush` / `withFilter…` / `withDiscv5` / `withPeerExchange` / `withRendezvous` calls plus a rate-limit default. Nothing else. So it overlaps with the explicit protocol flags an operator already uses, and it doesn't carry any of the broader meaning the Messaging API's `mode` is supposed to have.

Keep it on the CLI only if DST/QA actually depend on the shortcut. If they do, this should be the documented reason. If they don't, drop it.

## Code changes

1. **Add `(preset, mode, overrides?)` to the library Messaging API.**
   - In [`waku/api/api.nim`](waku/api/api.nim): a new `createNode` overload that builds a `WakuNodeConf` from `(preset, mode, overrides)` and delegates to the existing one.
   - Mirror in [`liblogosdelivery`](liblogosdelivery/logos_delivery_api/node_api.nim) — either a dedicated FFI call or a documented Messaging-API JSON shape (`{"preset": "...", "mode": "...", "overrides": {...}}`).
   - Define `WakuNodeConfOverrides` (likely `Option[T]` per field, derived from `WakuNodeConf`).

2. **Audit preset overrides.** For every field set by [`NetworkConf`](waku/factory/networks_config.nim#L20-L36), confirm: explicit override wins; warning is logged; resulting config validated.

3. **Drop cluster-id → preset auto-mapping.** Soft-deprecate first ([`cli_args.nim:926-935`](tools/confutils/cli_args.nim#L926-L935)), remove in a later release.

<details>
<summary>What <code>--preset</code> sets</summary>

See [`waku/factory/networks_config.nim`](waku/factory/networks_config.nim). A preset fills in: `entryNodes`, `clusterId`, `numShardsInCluster`, `maxMessageSize`, RLN config (contract, chain id, epoch, message limit), discv5 bootstrap, kad bootstrap, `mix`, `p2pReliability`.

</details>

<details>
<summary>What <code>mode</code> means</summary>

**In CLI today** ([`cli_args.nim:1126-1144`](tools/confutils/cli_args.nim#L1126-L1144))

A protocol-toggle shortcut. Nothing more.
- `Core` / `Edge` / `noMode`

**What `mode` should mean (Messaging API)**

A developer-facing role/profile. The app developer says "my app is a Core participant" or "my app is an Edge consumer", and the library translates that into a coherent set of defaults. But also, Messaging API runs background routines, which is not the case when one would use existing `--mode` from CLI.

This is why `mode` doesn't fit the CLI: an operator wiring a fleet by hand picks each of those values explicitly. And it should not be look like they're using anything close to Messaging API.

And note that in Messaging API `noMode` is impossible.

</details>
