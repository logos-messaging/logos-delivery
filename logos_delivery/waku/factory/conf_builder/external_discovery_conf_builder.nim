import chronicles, results, chronos
import logos_delivery/waku/factory/waku_conf
import ./kademlia_discovery_conf_builder

logScope:
  topics = "waku conf builder external discovery"

const DefaultPluginKadEnabled*: bool = false

type ExternalDiscoveryConfBuilder* = object
  ## Kademlia service discovery hosted by a plugin rather than in-process.
  ## The lookup intervals are the in-process backend's own defaults: the two
  ## are alternative hosts for one protocol, so they share the knobs.
  enabled*: Opt[bool]
  serviceLookupInterval*: Opt[Duration]
  randomLookupInterval*: Opt[Duration]

proc init*(T: type ExternalDiscoveryConfBuilder): ExternalDiscoveryConfBuilder =
  ExternalDiscoveryConfBuilder()

proc withEnabled*(b: var ExternalDiscoveryConfBuilder, enabled: bool) =
  b.enabled = Opt.some(enabled)

proc withServiceLookupInterval*(
    b: var ExternalDiscoveryConfBuilder, interval: Duration
) =
  b.serviceLookupInterval = Opt.some(interval)

proc withRandomLookupInterval*(
    b: var ExternalDiscoveryConfBuilder, interval: Duration
) =
  b.randomLookupInterval = Opt.some(interval)

proc build*(
    b: ExternalDiscoveryConfBuilder
): Result[Opt[ExternalDiscoveryConf], string] =
  # Unlike the in-process backend, nothing here can imply intent: the plugin
  # arrives at runtime and carries no config, and no network preset can name
  # it. Only the explicit flag enables it.
  if not b.enabled.get(DefaultPluginKadEnabled):
    return ok(Opt.none(ExternalDiscoveryConf))

  let serviceInterval = b.serviceLookupInterval.get(DefaultServiceLookupInterval)
  let randomInterval = b.randomLookupInterval.get(DefaultRandomLookupInterval)

  if serviceInterval <= ZeroDuration:
    return err("Plugin kad discovery service lookup interval must be greater than 0")
  if randomInterval <= ZeroDuration:
    return err("Plugin kad discovery random lookup interval must be greater than 0")

  return ok(
    Opt.some(
      ExternalDiscoveryConf(
        serviceLookupInterval: serviceInterval, randomLookupInterval: randomInterval
      )
    )
  )
