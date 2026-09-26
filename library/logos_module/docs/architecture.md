# Architecture

Where this module sits in the stack, and how much of that stack a given node
actually mounts.

## Layers

A message passes through three components on its way out:

```text
Logos Core  ·  your module or UI
     │  calls delivery_module methods (lp_* / QtRO, carried by logos-core)
     ▼
delivery_module = liblogosdelivery_module.a       ← logos-delivery, in Nim, linked into the plugin
     │  in-process
     ▼
logos-delivery             ← the node implementation
```

This directory is the packaging: `metadata.json`, the committed
`delivery_module.lidl`, the presets and docs, and the Nix flake that wraps
`liblogosdelivery_module` (this library's `liblogosdelivery_module` package,
built from `library/logos_module`) in logos-core's uniform plugin glue
(`interface: "cdylib"`). There is no C++ in between: the Nim archive exports
both the library's nim-ffi surface and the `logos_module_*` C ABI, and is
linked into the plugin as a Rust cdylib would be, so its calls to other
modules (`lp_*`) reach the protocol layer of the same image.

## Threads

A method call arrives on the host's thread as `logos_module_dispatch`,
becomes a CBOR request to the library's own export, and that thread polls
the node's context until the reply (nim-ffi's poll model, used in-process).
Events reach the host's emit callback straight from the node's thread. The
node asks `liblogos_rln_module` its RLN questions itself, through logos-core's
`lp_*` C ABI, from its own thread. The process holds three threads of its
own: the host's, logos-protocol's, and the node's. `start` and `stop` return
at once; their outcome is the `nodeStarted` / `nodeStopped` event the node
emits itself, because a stop can take longer than any call budget.

## What a node mounts

`createNode`'s `entryLayer` decides how much of the stack comes up:

| `entryLayer` | What you get |
| ------------ | ------------ |
| `"kernel"` | Transport node only. |
| `"messaging"` | Kernel plus the messaging client. |
| `"channels"` | Kernel, messaging, and reliable channels. **The default.** |

The layer you pick determines which methods work. On a kernel-only node,
`send`, `subscribe` and the `channel*` methods fail with "node has no messaging
client" or "no reliable channel manager". `getNodeInfo`, `storeQuery` and
metrics keep working.

The concrete configuration shapes — an app developer's full stack, a node
operator's public service node, a self-hosted network — are documented with
`createNode` in the [API reference](api_reference.rst).
