import chronicles, results, chronos
import libp2p/peerinfo
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
  bootstrapNodes*: seq[string]
    ## /p2p/ multiaddrs collected where the preset's entry nodes are processed.

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
    b: ExternalDiscoveryConfBuilder, sharedBootstrapNodes: seq[string] = @[]
): Result[Opt[ExternalDiscoveryConf], string] =
  ## `sharedBootstrapNodes` are the kademlia bootstrap peers (CLI and preset),
  ## which name DHT peers regardless of which host runs the protocol.
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

  var bootstrapNodes: seq[string]
  for nodeStr in sharedBootstrapNodes & b.bootstrapNodes:
    discard parseFullAddress(nodeStr).valueOr:
      return err("Failed to parse plugin discovery bootstrap node: " & $error)
    if nodeStr notin bootstrapNodes:
      bootstrapNodes.add(nodeStr)

  return ok(
    Opt.some(
      ExternalDiscoveryConf(
        serviceLookupInterval: serviceInterval,
        randomLookupInterval: randomInterval,
        bootstrapNodes: bootstrapNodes,
      )
    )
  )
