{.push raises: [].}

## A set of utilities to integrate EIP-1459 DNS-based discovery
## for Waku v2 nodes.
##
## EIP-1459 is defined in https://eips.ethereum.org/EIPS/eip-1459

import
  std/[options, net, sequtils, sugar],
  chronicles,
  chronos,
  metrics,
  eth/keys,
  eth/enr/enr,
  libp2p/crypto/crypto,
  libp2p/crypto/secp,
  libp2p/multiaddress,
  libp2p/peerid,
  dnsdisc/client
import libp2p/nameresolving/dnsresolver
import ../waku_core

export client

declarePublicGauge waku_dnsdisc_discovered, "number of nodes discovered"
declarePublicCounter waku_dnsdisc_errors, "number of waku dnsdisc errors", ["type"]

logScope:
  topics = "waku dnsdisc"

type WakuDnsDiscovery* = object
  client*: Client
  resolver*: Resolver

#####################
# DNS Discovery API #
#####################

proc emptyResolver*(domain: string): Future[string] {.async, gcsafe.} =
  info "Empty resolver called", domain = domain
  return ""

proc findPeers*(
    wdd: WakuDnsDiscovery
): Future[Result[seq[RemotePeerInfo], cstring]] {.async.} =
  ## Find peers to connect to using DNS based discovery

  info "Finding peers using Waku DNS discovery"

  # Synchronise client tree using configured resolver
  var tree: Tree
  try:
    tree = (await syncTree(wdd.resolver, wdd.client.loc)).tryGet()
  except Exception:
    error "Failed to synchronise client tree"
    waku_dnsdisc_errors.inc(labelValues = ["tree_sync_failure"])
    return err("Node discovery failed")

  let discoveredEnr = tree.getNodes().mapIt(it.record)

  if discoveredEnr.len > 0:
    info "Successfully discovered ENR", count = discoveredEnr.len
  else:
    trace "No ENR retrieved from client tree"

  var discoveredNodes: seq[RemotePeerInfo]

  for enr in discoveredEnr:
    # Convert discovered ENR to RemotePeerInfo and add to discovered nodes
    let peerInfo = enr.toRemotePeerInfo().valueOr:
      error "Failed to convert ENR to peer info", enr = $enr, error = error
      waku_dnsdisc_errors.inc(labelValues = ["peer_info_failure"])
      continue
    discoveredNodes.add(peerInfo)
  if discoveredNodes.len > 0:
    info "Successfully discovered nodes", count = discoveredNodes.len
    waku_dnsdisc_discovered.inc(discoveredNodes.len.int64)

  return ok(discoveredNodes)

proc init*(
    T: type WakuDnsDiscovery, locationUrl: string, resolver: Resolver
): Result[T, cstring] =
  ## Initialise Waku peer discovery via DNS

  info "init WakuDnsDiscovery", locationUrl = locationUrl

  let
    client = ?Client.init(locationUrl)
    wakuDnsDisc = WakuDnsDiscovery(client: client, resolver: resolver)

  info "init success"

  return ok(wakuDnsDisc)

proc retrieveDynamicBootstrapNodes*(
    dnsDiscoveryUrl: string, dnsAddrsNameServers: seq[IpAddress]
): Future[Result[seq[RemotePeerInfo], string]] {.async.} =
  ## Retrieve dynamic bootstrap nodes (DNS discovery)

  if dnsDiscoveryUrl != "":
    # DNS discovery
    info "Discovering nodes using Waku DNS discovery", url = dnsDiscoveryUrl

    var nameServers: seq[TransportAddress]
    for ip in dnsAddrsNameServers:
      nameServers.add(initTAddress(ip, Port(53))) # Assume all servers use port 53

    let dnsResolver = DnsResolver.new(nameServers)

    proc resolver(domain: string): Future[string] {.async, gcsafe.} =
      trace "resolving", domain = domain
      let resolved = await dnsResolver.resolveTxt(domain)
      if resolved.len > 0:
        return resolved[0] # Use only first answer

    var wakuDnsDiscovery = WakuDnsDiscovery.init(dnsDiscoveryUrl, resolver).errorOr:
      return (await value.findPeers()).mapErr(e => $e)
    warn "Failed to init Waku DNS discovery"

  info "No method for retrieving dynamic bootstrap nodes specified."
  ok(newSeq[RemotePeerInfo]()) # Return an empty seq by default
