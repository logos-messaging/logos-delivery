import std/strutils

import results, eth/enr/enr

import waku/waku_core/peers

type EntryNodeType {.pure.} = enum
  EnrTree
  Enr
  Multiaddr

proc classifyEntryNode(address: string): Result[EntryNodeType, string] =
  ## Classifies an entry node address by its type
  ## Returns the type as EntryNodeType enum
  if address.len == 0:
    return err("Empty entry node address")

  let lowerAddress = address.toLowerAscii()
  if lowerAddress.startsWith("enrtree:"):
    return ok(EnrTree)
  elif lowerAddress.startsWith("enr:"):
    return ok(Enr)
  elif address[0] == '/':
    return ok(Multiaddr)
  else:
    return
      err("Unrecognized entry node format. Must start with 'enrtree:', 'enr:', or '/'")

proc parseEnrToMultiaddrs(enrStr: string): Result[seq[string], string] =
  ## Parses an ENR string and extracts multiaddresses from it
  let enrRec = enr.Record.fromURI(enrStr).valueOr:
    return err("Invalid ENR record")

  let remotePeerInfo = toRemotePeerInfo(enrRec).valueOr:
    return err("Failed to convert ENR to peer info: " & $error)

  # Convert RemotePeerInfo addresses to multiaddr strings
  var multiaddrs: seq[string]
  for addr in remotePeerInfo.addrs:
    multiaddrs.add($addr & "/p2p/" & $remotePeerInfo.peerId)

  if multiaddrs.len == 0:
    return err("No valid addresses found in ENR")

  return ok(multiaddrs)

proc processEntryNodes*(
    entryNodes: seq[string]
): Result[(seq[string], seq[string], seq[string]), string] =
  ## Processes entry nodes and returns (enrTreeUrls, bootstrapEnrs, staticNodes)
  ## ENRTree URLs for DNS discovery, ENR records for bootstrap, multiaddrs for static nodes
  var enrTreeUrls: seq[string]
  var bootstrapEnrs: seq[string]
  var staticNodes: seq[string]

  for node in entryNodes:
    let nodeType = classifyEntryNode(node).valueOr:
      return err("Entry node error: " & error)

    case nodeType
    of EnrTree:
      # ENRTree URLs go to DNS discovery configuration
      enrTreeUrls.add(node)
    of Enr:
      # ENR records go to bootstrap nodes for discv5
      bootstrapEnrs.add(node)
      # Additionally, extract multiaddrs for static connections
      let multiaddrsRes = parseEnrToMultiaddrs(node)
      if multiaddrsRes.isOk():
        for maddr in multiaddrsRes.get():
          staticNodes.add(maddr)
      # If we can't extract multiaddrs, just use it as bootstrap (already added above)
    of Multiaddr:
      # Multiaddresses go to static nodes
      staticNodes.add(node)

  return ok((enrTreeUrls, bootstrapEnrs, staticNodes))
