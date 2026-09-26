# RLN

The delivery library (liblogosdelivery) does not implement RLN itself — it
asks an external RLN module for every RLN operation. In the module image the
node asks `liblogos_rln_module` directly, through logos-core's `lp_*` C ABI,
from its own thread (`logos_delivery/waku/rln/rln_lez/wire.nim`): one
`lp_invoke_async` per question with the op's own deadline, the reply crossing
back over a thread signal. The registry id and rln identifier every question
carries come from the node's preset (`presets.nim`),
handed to the library before the node is created. The library is otherwise
implementation-agnostic: it never starts the backend, and the RLN module's
replies are decoded by the library's own parsers, verbatim.

A `get_membership_state` reply crosses verbatim; the other three answer the
result envelope. Both are decoded by the library's own parsers — the schema
is the RLN module's and the delivery library's, not modelled here. A
transport failure (nothing reachable, a timeout) is TRANSIENT; a refusal by
the module itself is PERMANENT, because retrying a contract mismatch cannot
fix it. If nothing answers a question at all, the library times it out
itself and everything non-RLN keeps working.

## Turning RLN on

**There is no RLN method to call.** RLN comes from the network `preset` in
the `createNode` config, because every value it needs — the registry, the
epoch size, the application identifier — is a property of the deployment
rather than of the caller. A client picks a network and gets whatever rate
limiting that network runs.

Every shipped preset has RLN **off** (see [`networks.md`](./networks.md)).

- The library mounts RLN when the module says so at node creation (the
  `rlnPlugin` flag in the create request, set from the preset). There is no
  callback table to install and no bridge to bring up.
- `createNode` hands the preset's registry id and rln identifier to the
  library and opens the lp client to the RLN module; nothing reaches the
  chain at creation. `rlnState` / `rlnStateChanged` then read `Ready`
  (`Disabled` when the preset has RLN off).
- Nothing here starts `liblogos_rln_module`: it is a module of its own, up
  once loaded.
- `liblogos_rln_module` is an `optional_dependency`, so the host neither
  loads it nor requires it: a node whose preset has RLN off runs without the
  RLN stack installed at all. A node on an RLN-enabled preset needs it — and
  its own dep, `liblogos_lez_rln_module` — loaded before `createNode`, or
  `createNode` fails.
- `start` runs the library's `get_membership_state` gate: the node's
  membership must already be `active` or `grace_period` — registration
  happens out-of-band, through the RLN module, not through this library.
  Without one the node still starts, and every `send` retries the proof
  each round (`messageQueued`) until a membership exists.

`Ready` means the module can ask. It does not mean the RLN module's
valid-root window is warm — that is a background refresh the RLN module does
not currently expose a probe for.

Every send queries `get_epoch_quota` and is queued while `remaining` is 0.

### Presets for a test or local deployment

`LOGOS_DELIVERY_RLN_PRESETS` names a JSON file whose entries are merged over
the built-in table, which is how a rig points a node at its own registry
without any public API for it:

```json
{
  "": {
    "enabled": true,
    "registry-id": "logos:testnet:<64 hex chars — the registration program's config account>",
    "epoch-size-sec": 120,
    "max-epoch-gap": 1
  }
}
```

`rln-identifier` is optional and defaults to this application's scope,
`sha256("rln/logos-delivery/v0.0.1")`. Name one only for a deployment that
needs a scope of its own — every node that must validate another's proofs has
to use the same value, and two that disagree reject each other's messages as
invalid rather than reporting a misconfiguration. The 32 bytes are arbitrary
to the protocol: the circuit path reduces them with `hash_to_field_le`
(Keccak-256) however they were chosen.

Keys are preset names spelled exactly as the delivery library spells them —
`""`, `twn`, `logos.dev`, `logos.test`, `status.prod` — and matched exactly.
The empty name above is the preset-less config the library also accepts.

A variant spelling is an error, not a miss: `logostest` in this file, or in a
node's `preset`, fails rather than resolving to `logos.test`. The library
accepts some of those variants for its own network config, so a node could
otherwise come up on the right network with RLN silently off.

A file that cannot be read or parsed, an unknown preset name, or an enabled
entry missing a required field all fail `createNode` rather than quietly
producing a node without the rate limiting its deployment expects.

## Running the e2e

`tests/e2e/run.sh` boots a logosctl daemon over the four module bundles and
asserts the bring-up chain; its header documents the env knobs. The daemon
log — `<run dir>/session/logs/daemon.log` — carries the library's log lines.

## Time budgets

Each question is one `lp_invoke_async` carrying its own deadline — 70 s for
the registry reads (`get_membership_state`, `generate_proof`), 10 s for
`get_epoch_quota` and `validate_proof` — and the library waits that long plus
a margin before failing the question itself. The reply arrives on the
protocol layer's completion callback, which wakes the node's thread.
