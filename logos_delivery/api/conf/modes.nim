## Leaf module for the app-level mode / entry-layer enums.
##
## These appear on `LogosDeliveryNodeConf` (in the leaf `tools/confutils/cli_args`), so
## they must live in a module that `cli_args` can import without a cycle — i.e.
## a module that imports nothing from the config/api layers. `logos_delivery_conf`
## re-exports them so consumers still get them from there.

import results

type LogosDeliveryMode* {.pure.} = enum
  ## Drives the kernel-internal protocol mountings. Applied only for the
  ## `messaging` / `channels` entry layers; ignored when `entryLayer == kernel`.
  Edge # client-only node
  Core # full service node

type EntryLayer* {.pure.} = enum
  ## Frontend (CLI/JSON) token that names a mount height. The frontends
  ## translate it into which per-layer configs are present on
  ## `LogosDeliveryConf`. The library mounts a layer iff its config is present.
  kernel # transport kernel only; an explicit `mode` is rejected
  messaging # kernel + messaging client
  channels # kernel + messaging + reliable channels

type ModeProtocolFlags* = object
  ## The protocol flags a mode implies. An unset field means the mode has no
  ## value for that protocol.
  relay*: Opt[bool]
  filter*: Opt[bool]
  lightpush*: Opt[bool]
  store*: Opt[bool]
  discv5Discovery*: Opt[bool]
  peerExchange*: Opt[bool]
  rendezvous*: Opt[bool]

proc protocolFlags*(mode: LogosDeliveryMode): ModeProtocolFlags =
  ## The single source of what each mode means.
  case mode
  of LogosDeliveryMode.Core:
    ModeProtocolFlags(
      relay: Opt.some(true),
      filter: Opt.some(true),
      lightpush: Opt.some(true),
      discv5Discovery: Opt.some(true),
      peerExchange: Opt.some(true),
      rendezvous: Opt.some(true),
    )
  of LogosDeliveryMode.Edge:
    ModeProtocolFlags(
      peerExchange: Opt.some(true),
      relay: Opt.some(false),
      filter: Opt.some(false),
      lightpush: Opt.some(false),
      store: Opt.some(false),
    )

proc applyMode*[T](conf: var T, mode: LogosDeliveryMode) =
  ## Applies the mode's protocol flags (`protocolFlags`) to any config that
  ## has those fields. A tri-state (`Opt`) field can hold an explicit user
  ## value, so it is set only when it is unset; a plain field holds only
  ## defaults, so it is set whenever the mode has a value.
  let flags = protocolFlags(mode)
  template apply(field, value: untyped) =
    when field is Opt[bool]:
      if field.isNone():
        field = value
    else:
      if value.isSome():
        field = value.get()

  apply(conf.relay, flags.relay)
  apply(conf.filter, flags.filter)
  apply(conf.lightpush, flags.lightpush)
  apply(conf.store, flags.store)
  apply(conf.discv5Discovery, flags.discv5Discovery)
  apply(conf.peerExchange, flags.peerExchange)
  apply(conf.rendezvous, flags.rendezvous)
