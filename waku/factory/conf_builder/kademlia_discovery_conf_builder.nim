import chronicles, std/options, results
import libp2p/[peerid, multiaddress, peerinfo]
import waku/factory/waku_conf

logScope:
  topics = "waku conf builder kademlia discovery"

#######################################
## Kademlia Discovery Config Builder ##
#######################################
type KademliaDiscoveryConfBuilder* = object
  enabled*: bool
  bootstrapNodes*: seq[string]

proc init*(T: type KademliaDiscoveryConfBuilder): KademliaDiscoveryConfBuilder =
  KademliaDiscoveryConfBuilder()

proc withEnabled*(b: var KademliaDiscoveryConfBuilder, enabled: bool) =
  b.enabled = enabled

proc withBootstrapNodes*(
    b: var KademliaDiscoveryConfBuilder, bootstrapNodes: seq[string]
) =
  b.bootstrapNodes = bootstrapNodes

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

  return ok(some(KademliaDiscoveryConf(bootstrapNodes: parsedNodes)))
