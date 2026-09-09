import chronicles, results, chronos
import logos_delivery/waku/factory/waku_conf

logScope:
  topics = "waku conf builder external discovery"

const
  DefaultExternalDiscoveryEnabled*: bool = false
  DefaultExternalRandomLookupIntervalMs*: uint32 = 60_000
  DefaultExternalServiceLookupIntervalMs*: uint32 = 60_000

type ExternalDiscoveryConfBuilder* = object
  enabled*: Opt[bool]
  serviceLookupIntervalMs*: Opt[uint32]
  randomLookupIntervalMs*: Opt[uint32]

proc init*(T: type ExternalDiscoveryConfBuilder): ExternalDiscoveryConfBuilder =
  ExternalDiscoveryConfBuilder()

proc withEnabled*(b: var ExternalDiscoveryConfBuilder, enabled: bool) =
  b.enabled = Opt.some(enabled)

proc withServiceLookupIntervalMs*(
    b: var ExternalDiscoveryConfBuilder, intervalMs: uint32
) =
  b.serviceLookupIntervalMs = Opt.some(intervalMs)

proc withRandomLookupIntervalMs*(
    b: var ExternalDiscoveryConfBuilder, intervalMs: uint32
) =
  b.randomLookupIntervalMs = Opt.some(intervalMs)

proc build*(
    b: ExternalDiscoveryConfBuilder
): Result[Opt[ExternalDiscoveryConf], string] =
  # Unlike kademlia, nothing here can imply intent: the plugin arrives at
  # runtime and carries no config, so only the explicit flag enables it.
  if not b.enabled.get(DefaultExternalDiscoveryEnabled):
    return ok(Opt.none(ExternalDiscoveryConf))

  let serviceIntervalMs =
    b.serviceLookupIntervalMs.get(DefaultExternalServiceLookupIntervalMs)
  let randomIntervalMs =
    b.randomLookupIntervalMs.get(DefaultExternalRandomLookupIntervalMs)

  if serviceIntervalMs == 0:
    return err("External discovery service lookup interval must be greater than 0")
  if randomIntervalMs == 0:
    return err("External discovery random lookup interval must be greater than 0")

  return ok(
    Opt.some(
      ExternalDiscoveryConf(
        serviceLookupIntervalMs: serviceIntervalMs,
        randomLookupIntervalMs: randomIntervalMs,
      )
    )
  )
