## This module is aimed to collect and provide information about the state of the node,
## such as its version, metrics values, etc.
## It has been originally designed to be used by the debug API, which acts as a consumer of
## this information, but any other module can populate the information it needs to be
## accessible through the debug API.

import std/[tables, sequtils, strutils]
import metrics, eth/p2p/discoveryv5/enr, libp2p/peerid, stew/byteutils
import logos_delivery/waku/[waku_node, net/bound_ports]
import logos_delivery/waku/factory/waku_conf

type
  NodeInfoId* {.pure.} = enum
    Version
    Metrics
    MyMultiaddresses
    MyENR
    MyPeerId
    MyBoundPorts
    MyMixPubKey
    MaxMessageSize

  WakuStateInfo* {.requiresInit.} = object
    node: WakuNode
    conf: WakuConf

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
    return $self.node.ports
  of NodeInfoId.MyMixPubKey:
    ## Empty when the mix protocol is not mounted on this node.
    if self.node.wakuMix.isNil():
      return ""
    return self.node.wakuMix.pubKey.to0xHex()
  of NodeInfoId.MaxMessageSize:
    ## Configured max message size (in bytes) for this node.
    return $self.conf.maxMessageSizeBytes
  else:
    return "unknown info item id"

proc init*(T: typedesc[WakuStateInfo], node: WakuNode, conf: WakuConf): T =
  return WakuStateInfo(node: node, conf: conf)
