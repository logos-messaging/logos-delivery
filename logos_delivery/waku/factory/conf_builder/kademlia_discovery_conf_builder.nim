import logos_delivery/waku/compat/option_valueor
import chronicles, std/options, results
import logos_delivery/waku/discovery/waku_kademlia
import chronos
import libp2p/[peerid, multiaddress, peerinfo]
import libp2p/protocols/kademlia/types
import libp2p/protocols/service_discovery/types as sd_types

logScope:
  topics = "waku conf builder kademlia discovery"

const
  DefaultKadEnabled*: bool = false
  DefaultRandomLookupInterval* = chronos.seconds(60)
  DefaultServiceLookupInterval* = chronos.seconds(60)

type KademliaDiscoveryConfBuilder* = object
  enabled*: Option[bool]
  bootstrapNodes*: seq[string]
  randomLookupInterval*: Option[Duration]
  serviceLookupInterval*: Option[Duration]

proc init*(T: type KademliaDiscoveryConfBuilder): KademliaDiscoveryConfBuilder =
  KademliaDiscoveryConfBuilder()

proc withEnabled*(b: var KademliaDiscoveryConfBuilder, enabled: bool) =
  b.enabled = some(enabled)

proc withBootstrapNodes*(
    b: var KademliaDiscoveryConfBuilder, bootstrapNodes: seq[string]
) =
  b.bootstrapNodes = bootstrapNodes

proc withRandomLookupInterval*(
    b: var KademliaDiscoveryConfBuilder, interval: Duration
) =
  b.randomLookupInterval = some(interval)

proc withServiceLookupInterval*(
    b: var KademliaDiscoveryConfBuilder, interval: Duration
) =
  b.serviceLookupInterval = some(interval)

proc build*(
    b: KademliaDiscoveryConfBuilder
): Result[Option[KademliaDiscoveryConf], string] =
  # Explicit disable wins: enabled=false disables regardless of bootstrap nodes.
  if b.enabled == some(false):
    return ok(none(KademliaDiscoveryConf))
  # Otherwise enabled if config-enabled or any bootstrap nodes are provided.
  if not b.enabled.get(DefaultKadEnabled) and b.bootstrapNodes.len == 0:
    return ok(none(KademliaDiscoveryConf))

  var parsedNodes: seq[(PeerId, seq[MultiAddress])]
  for nodeStr in b.bootstrapNodes:
    let (peerId, ma) = parseFullAddress(nodeStr).valueOr:
      return err("Failed to parse kademlia bootstrap node: " & error)
    parsedNodes.add((peerId, @[ma]))

  return ok(
    some(
      KademliaDiscoveryConf(
        bootstrapNodes: parsedNodes,
        randomLookupInterval: b.randomLookupInterval.get(DefaultRandomLookupInterval),
        serviceLookupInterval: b.serviceLookupInterval.get(DefaultServiceLookupInterval),
        kadDhtConfig: KadDHTConfig.new(),
        discoConfig: sd_types.ServiceDiscoveryConfig.new(),
        clientMode: false,
        xprPublishing: true,
      )
    )
  )
