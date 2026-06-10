import chronicles, std/options, results
import libp2p/[peerid, multiaddress, peerinfo]
import logos_delivery/waku/factory/waku_conf

logScope:
  topics = "waku conf builder kademlia discovery"

const DefaultKadEnabled*: bool = false

#######################################
## Kademlia Discovery Config Builder ##
#######################################
type KademliaDiscoveryConfBuilder* = object
  enabled*: Option[bool]
  bootstrapNodes*: seq[string]

proc init*(T: type KademliaDiscoveryConfBuilder): KademliaDiscoveryConfBuilder =
  KademliaDiscoveryConfBuilder()

proc withEnabled*(b: var KademliaDiscoveryConfBuilder, enabled: bool) =
  b.enabled = some(enabled)

proc withBootstrapNodes*(
    b: var KademliaDiscoveryConfBuilder, bootstrapNodes: seq[string]
) =
  b.bootstrapNodes = bootstrapNodes

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

  return ok(some(KademliaDiscoveryConf(bootstrapNodes: parsedNodes)))
