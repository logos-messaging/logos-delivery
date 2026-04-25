## This module is aimed to collect and provide information about the state of the node,
## such as its version, metrics values, etc.
## It has been originally designed to be used by the debug API, which acts as a consumer of
## this information, but any other module can populate the information it needs to be
## accessible through the debug API.

import std/[tables, sequtils, strutils]
import metrics, eth/p2p/discoveryv5/enr, libp2p/peerid
import waku/[waku_node, net/bound_ports]

type
  NodeInfoId* {.pure.} = enum
    Version
    Metrics
    MyMultiaddresses
    MyENR
    MyPeerId
    MyBoundPorts

  WakuStateInfo* {.requiresInit.} = object
    node: WakuNode

proc getAllPossibleInfoItemIds*(self: WakuStateInfo): seq[NodeInfoId] =
  ## Returns all possible options that can be queried to learn about the node's information.
  var ret = newSeq[NodeInfoId](0)
  for item in NodeInfoId:
    ret.add(item)
  return ret

proc getMetrics(): string =
  {.gcsafe.}:
    return defaultRegistry.toText() ## defaultRegistry is {.global.} in metrics module

proc getNodeInfoItem*(self: WakuStateInfo, infoItemId: NodeInfoId): string =
  ## Returns the content of the info item with the given id if it exists.
  case infoItemId
  of NodeInfoId.Version:
    return git_version
  of NodeInfoId.Metrics:
    return getMetrics()
  of NodeInfoId.MyMultiaddresses:
    return self.node.info().listenAddresses.join(",")
  of NodeInfoId.MyENR:
    return self.node.enr.toURI()
  of NodeInfoId.MyPeerId:
    return $PeerId(self.node.peerId())
  of NodeInfoId.MyBoundPorts:
    return self.node.ports.toJsonString()
  else:
    return "unknown info item id"

proc init*(T: typedesc[WakuStateInfo], node: WakuNode): T =
  return WakuStateInfo(node: node)
