import chronicles, std/options, results
import chronos
import libp2p/[peerid, multiaddress, peerinfo, extended_peer_record]
import waku/factory/waku_conf

logScope:
  topics = "waku conf builder kademlia discovery"

#######################################
## Kademlia Discovery Config Builder ##
#######################################
type KademliaDiscoveryConfBuilder* = object
  enabled*: bool
  bootstrapNodes*: seq[string]
  servicesToAdvertise*: seq[(string, seq[byte])]
  servicesToDiscover*: seq[string]
  randomLookupInterval*: Duration
  serviceLookupInterval*: Duration

proc init*(T: type KademliaDiscoveryConfBuilder): KademliaDiscoveryConfBuilder =
  KademliaDiscoveryConfBuilder()

proc withEnabled*(b: var KademliaDiscoveryConfBuilder, enabled: bool) =
  b.enabled = enabled

proc withBootstrapNodes*(
    b: var KademliaDiscoveryConfBuilder, bootstrapNodes: seq[string]
) =
  b.bootstrapNodes = bootstrapNodes

proc withServicesToAdvertise*(
    b: var KademliaDiscoveryConfBuilder, services: seq[(string, seq[byte])]
) =
  b.servicesToAdvertise = services

proc withServicesToDiscover*(
    b: var KademliaDiscoveryConfBuilder, services: seq[string]
) =
  b.servicesToDiscover = services

proc withRandomLookupInterval*(
    b: var KademliaDiscoveryConfBuilder, interval: Duration
) =
  b.randomLookupInterval = interval

proc withServiceLookupInterval*(
    b: var KademliaDiscoveryConfBuilder, interval: Duration
) =
  b.serviceLookupInterval = interval

proc build*(
    b: KademliaDiscoveryConfBuilder
): Result[Option[KademliaDiscoveryConf], string] =
  # Kademlia is enabled if explicitly enabled OR if bootstrap nodes are provided
  let enabled = b.enabled or b.bootstrapNodes.len > 0
  if not enabled:
    return ok(none(KademliaDiscoveryConf))

  var parsedNodes: seq[(PeerId, seq[MultiAddress])]
  for nodeStr in b.bootstrapNodes:
    let (peerId, ma) = parseFullAddress(nodeStr).valueOr:
      return err("Failed to parse kademlia bootstrap node: " & error)
    parsedNodes.add((peerId, @[ma]))

  var servicesToAdvertise: seq[ServiceInfo]
  for (serviceId, data) in b.servicesToAdvertise:
    servicesToAdvertise.add(ServiceInfo(id: serviceId, data: data))

  return ok(
    some(
      KademliaDiscoveryConf(
        bootstrapNodes: parsedNodes,
        servicesToAdvertise: servicesToAdvertise,
        servicesToDiscover: b.servicesToDiscover,
        randomLookupInterval: b.randomLookupInterval,
        serviceLookupInterval: b.serviceLookupInterval,
      )
    )
  )
