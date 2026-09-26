# delivery_module

logos-delivery as a Logos Core module: the library plus the `logos_module_*`
C ABI logos-core's plugin glue calls, in one image. Three parts and nothing
between them: logos-core carries every call, this answers the delivery
contract, and `liblogos_rln_module` answers the RLN questions the node asks.

- `module.nim` — the contract's handlers, on nim-ffi's in-image host
  (`ffi/poll_host`); the library's events and RLN questions come to it as
  they are emitted, on the node's thread.
- `presets.nim` — which network turns RLN on, and with what
  (`$LOGOS_DELIVERY_RLN_PRESETS` overrides the built-ins).
- `delivery_module.lidl` — the contract; `metadata.json`, `CMakeLists.txt` —
  what logos-module-builder needs (`interface: "cdylib"`, no C++ of its own).
- `docs/` — [architecture](docs/architecture.md), [RLN](docs/rln.md).
- `tests/e2e/` — the module under a real `logoscore`, over RPC.

## Build

```sh
nix build '.#liblogosdelivery_module'          # the module image, a static archive
nix build '.#delivery_module-lgx-portable'     # the bundle logoscore installs
nix build '.#liblogos_rln_module-lgx' '.#liblogos_lez_rln_module-lgx'   # RLN, for an RLN-enabled preset
```

## Run

```sh
lgpm --modules-dir ./modules --allow-unsigned install --file result/*.lgx
logoscore -D -m ./modules &
logoscore load-module liblogos_rln_module        # optional: before createNode on an RLN-enabled preset
logoscore load-module delivery_module
logoscore call delivery_module createNode '{"preset": "logos.test"}'
logoscore call delivery_module start
logoscore call delivery_module subscribe /logos/1/demo/proto
logoscore call delivery_module send /logos/1/demo/proto "hello"
```

`start` and `stop` return at once; their outcome is the `nodeStarted` /
`nodeStopped` event. The host process holds three threads: the host's,
logos-protocol's, and the node's.
