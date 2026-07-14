## Leaf module for the app-level mode / entry-layer enums.
##
## These appear on `WakuNodeConf` (in the leaf `tools/confutils/cli_args`), so
## they must live in a module that `cli_args` can import without a cycle — i.e.
## a module that imports nothing from the config/api layers. `logos_delivery_conf`
## re-exports them so consumers still get them from there.

type LogosDeliveryMode* {.pure.} = enum
  ## Drives the kernel-internal protocol mountings. Applied only for the
  ## `messaging` / `channels` entry layers; ignored when `entryLayer == kernel`.
  Edge # client-only node
  Core # full service node

type EntryLayer* {.pure.} = enum
  ## Selects which API layer `LogosDelivery` instantiates.
  kernel # transport kernel only; ignores `mode` and uses the config as-is
  messaging # kernel + messaging client
  channels # kernel + messaging + reliable channels
